/// The arithmetic behind every accessibility claim this app makes about colour.
///
/// ============================================================================
/// WHY THIS FILE EXISTS AT ALL
/// ============================================================================
///
/// "That looks readable" is not a fact anybody else can check, it changes with
/// the monitor it was said on, and it is exactly the judgement a player with
/// different colour vision cannot make on our behalf. Every claim in this
/// repository about colour is therefore a NUMBER produced by the functions
/// below, and `test/colour_math_test.dart` pins those functions against
/// published reference values before anything is judged by them.
///
/// That ordering matters more than it looks. A contrast checker with a sign
/// error still returns numbers, still prints a table, and still says PASS —
/// it just says it about the wrong thing. So the calculator is verified
/// FIRST, against pairs whose answers were computed by somebody else (black on
/// white is exactly 21:1, and so on), and only then is it allowed to grade the
/// palette.
///
/// ============================================================================
/// PURE DART, NO `dart:ui`
/// ============================================================================
///
/// Colours are plain `int`s in 0xAARRGGBB, not `Color` objects. That is what
/// lets `tool/palette_report.dart` run this under a bare `dart run` with no
/// Flutter engine underneath it, and it is the same reason `lib/game/` is pure
/// Dart: a thing with no framework under it can be checked cheaply and
/// everywhere. `lib/ui/palette.dart` is pure Dart for the same reason;
/// `lib/main.dart` and `lib/ui/game_screens.dart` do the one-line conversion
/// into `Color`.
library;

import 'dart:math' as math;

// =============================================================================
// Channels
// =============================================================================

/// The alpha byte of [argb], 0..255.
int alphaOf(int argb) => (argb >> 24) & 0xFF;

/// The red byte of [argb], 0..255.
int redOf(int argb) => (argb >> 16) & 0xFF;

/// The green byte of [argb], 0..255.
int greenOf(int argb) => (argb >> 8) & 0xFF;

/// The blue byte of [argb], 0..255.
int blueOf(int argb) => argb & 0xFF;

/// Packs four 0..255 bytes back into 0xAARRGGBB.
int packArgb(int a, int r, int g, int b) =>
    ((a & 0xFF) << 24) | ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF);

/// `0xAARRGGBB` as the eight-digit string a designer would recognise.
String hexOf(int argb) =>
    '#${argb.toUnsigned(32).toRadixString(16).padLeft(8, '0').toUpperCase()}';

/// True when [argb] lets nothing through: alpha is exactly 255.
///
/// Load-bearing rather than cosmetic. A relative luminance is a property of
/// LIGHT LEAVING THE SCREEN, so it is only defined once every layer under a
/// colour has been resolved. Asking for the luminance of a half-transparent
/// colour is asking a question with no answer, and the honest response is to
/// refuse — see [relativeLuminance].
bool isOpaque(int argb) => alphaOf(argb) == 0xFF;

// =============================================================================
// Compositing
// =============================================================================

/// Lays [over] on top of [under] and returns what is actually on screen.
///
/// SOURCE-OVER, IN GAMMA-ENCODED sRGB, ON PURPOSE. Blending in linear light is
/// the physically correct thing to do and is NOT what Flutter does: a Skia
/// canvas composites the encoded bytes. Since the whole point of this function
/// is to predict the pixel a player will actually see, it has to make the same
/// (slightly wrong) choice the renderer makes. `test/colour_math_test.dart`
/// pins it against Flutter's own `Color.alphaBlend` so the two cannot drift.
///
/// [under] is required to be opaque: compositing onto something transparent
/// leaves a colour that still has no defined luminance, which just moves the
/// problem. Flatten a stack from the bottom up with [flatten].
int composite(int over, int under) {
  assert(isOpaque(under), 'the layer underneath must be opaque, got '
      '${hexOf(under)} — flatten the stack from the bottom up');
  final double a = alphaOf(over) / 255.0;
  int mix(int o, int u) => (a * o + (1.0 - a) * u).round().clamp(0, 255);
  return packArgb(
    0xFF,
    mix(redOf(over), redOf(under)),
    mix(greenOf(over), greenOf(under)),
    mix(blueOf(over), blueOf(under)),
  );
}

/// Flattens a stack of layers into the one colour on screen.
///
/// [base] is the bottom, [layers] are laid on in order — first element first,
/// last element on top. The result is always opaque.
int flatten(int base, List<int> layers) {
  int out = base;
  for (final int layer in layers) {
    out = composite(layer, out);
  }
  return out;
}

// =============================================================================
// WCAG 2.x contrast
// =============================================================================

/// The channel transfer function WCAG 2.x SPECIFIES, applied to one 0..1
/// channel.
///
/// Note the 0.03928 threshold. The colorimetrically correct sRGB breakpoint is
/// 0.04045 — see [linearizeSrgb], which uses it — and the two differ because
/// the WCAG text quotes an older draft of the sRGB standard. The difference is
/// under one part in a hundred thousand of the final ratio and could not change
/// a verdict. It is kept anyway, because the claim being made here is
/// "conforms to WCAG 2.x", and conforming to a specification means computing
/// what the specification says rather than what it should have said.
double _wcagChannel(double c) =>
    c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

/// WCAG 2.x relative luminance of an OPAQUE colour: 0.0 for black, 1.0 for
/// white.
///
/// The three weights are the sRGB luminance coefficients — green carries most
/// of the perceived brightness, blue almost none — which is why a saturated
/// blue and a saturated yellow of the "same" intensity are nowhere near the
/// same brightness.
///
/// Throws on a translucent colour rather than quietly ignoring the alpha. See
/// [isOpaque].
double relativeLuminance(int argb) {
  if (!isOpaque(argb)) {
    throw ArgumentError.value(
      hexOf(argb),
      'argb',
      'relative luminance is only defined for an opaque colour; composite it '
          'onto its background first',
    );
  }
  final double r = _wcagChannel(redOf(argb) / 255.0);
  final double g = _wcagChannel(greenOf(argb) / 255.0);
  final double b = _wcagChannel(blueOf(argb) / 255.0);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/// The WCAG 2.x contrast ratio between two opaque colours: `(L1 + 0.05) /
/// (L2 + 0.05)`, lighter over darker. Ranges from 1.0 (identical) to 21.0
/// (black against white).
///
/// The 0.05 is not padding. It stands for ambient light reflecting off the
/// screen — the reason a "black" phone in daylight is really dark grey — and it
/// is what stops the ratio running to infinity for anything against pure black.
///
/// Symmetric by construction: the larger luminance is always the numerator, so
/// callers never have to know which colour is the text.
double contrastRatio(int a, int b) {
  final double la = relativeLuminance(a);
  final double lb = relativeLuminance(b);
  final double hi = la > lb ? la : lb;
  final double lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// The bar every text/background pair in this app has to clear.
///
/// 4.5:1 is WCAG 2.x success criterion 1.4.3, Contrast (Minimum), level AA, for
/// body-sized text. AA rather than AAA's 7:1 because AA is the level that
/// public-sector accessibility law in most of the world actually references,
/// and 4.5:1 is roughly the point at which a reader with 20/40 vision — about
/// what uncorrected age-related loss produces — reads text as comfortably as
/// someone with 20/20 reads text at 3:1.
///
/// The standard also allows 3:1 for LARGE text (18pt, or 14pt bold). This app
/// does not take that discount anywhere: every pair below is graded at 4.5:1
/// whatever size it is drawn at, because a size exemption is a promise about a
/// font size that a later layout change can quietly break.
const double wcagAaTextContrast = 4.5;

/// The bar for a non-text thing that has to be seen to be used: borders, the
/// pause glyph's outline, the edge of a button.
///
/// WCAG 2.x success criterion 1.4.11, Non-text Contrast, level AA.
const double wcagAaNonTextContrast = 3.0;

// =============================================================================
// CIELAB — the space colour DIFFERENCE is measured in
// =============================================================================

/// The exact sRGB electro-optical transfer function, for one 0..1 channel.
///
/// Used by everything colorimetric below ([toLab], [simulateDichromacy]) as
/// distinct from [_wcagChannel], which reproduces a specification's typo on
/// purpose. Mixing the two up would be harmless numerically and confusing
/// forever, so they are two functions with two names.
double linearizeSrgb(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

/// The inverse of [linearizeSrgb]: linear light back to an encoded channel.
double encodeSrgb(double c) {
  final double v = c.clamp(0.0, 1.0);
  return v <= 0.0031308 ? v * 12.92 : 1.055 * math.pow(v, 1 / 2.4) - 0.055;
}

/// A colour in CIE L*a*b*, D65.
///
/// L* is lightness, 0..100. a* runs green-to-red and b* blue-to-yellow, both
/// unbounded in principle and roughly -128..128 in practice.
class Lab {
  /// Lightness.
  final double l;

  /// Green (negative) to red (positive).
  final double a;

  /// Blue (negative) to yellow (positive).
  final double b;

  const Lab(this.l, this.a, this.b);

  @override
  String toString() =>
      'Lab(${l.toStringAsFixed(4)}, ${a.toStringAsFixed(4)}, '
      '${b.toStringAsFixed(4)})';
}

/// D65 white point, the reference sRGB is defined against.
///
/// These are the COLUMN SUMS of the sRGB-to-XYZ matrix below, not the rounded
/// D65 values from a reference table, and the distinction is not pedantry: the
/// white point has to be whatever the matrix maps (1, 1, 1) to, or a neutral
/// grey comes out of [toLab] with a small non-zero a* and b*. The published
/// tabulated Y is 1.00000 and the matrix's own column sums to 1.0000001;
/// dividing by the wrong one of those tilts every grey off the achromatic axis
/// by about four parts in ten million, which is invisible in a report and
/// visible in a test that asserts greys are grey.
const double _xn = 0.4124564 + 0.3575761 + 0.1804375;
const double _yn = 0.2126729 + 0.7151522 + 0.0721750;
const double _zn = 0.0193339 + 0.1191920 + 0.9503041;

/// An opaque sRGB colour as CIE L*a*b*.
///
/// Two steps, both standard: linear sRGB into CIE XYZ with the sRGB primaries
/// matrix, then XYZ into Lab against the D65 white point above.
Lab toLab(int argb) {
  final double r = linearizeSrgb(redOf(argb) / 255.0);
  final double g = linearizeSrgb(greenOf(argb) / 255.0);
  final double b = linearizeSrgb(blueOf(argb) / 255.0);

  final double x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b;
  final double y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b;
  final double z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b;

  // The cube-root curve, with the linear segment near black that keeps its
  // slope finite at the origin.
  double f(double t) {
    const double delta = 6.0 / 29.0;
    return t > delta * delta * delta
        ? math.pow(t, 1.0 / 3.0).toDouble()
        : t / (3.0 * delta * delta) + 4.0 / 29.0;
  }

  final double fx = f(x / _xn);
  final double fy = f(y / _yn);
  final double fz = f(z / _zn);

  return Lab(116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz));
}

// =============================================================================
// CIEDE2000
// =============================================================================

double _deg(double radians) => radians * 180.0 / math.pi;
double _rad(double degrees) => degrees * math.pi / 180.0;

/// Hue angle in degrees, normalised into [0, 360).
double _hue(double b, double aPrime) {
  if (aPrime == 0.0 && b == 0.0) return 0.0;
  final double h = _deg(math.atan2(b, aPrime));
  return h < 0.0 ? h + 360.0 : h;
}

/// The CIEDE2000 colour difference, ΔE₀₀, between two Lab colours.
///
/// ============================================================================
/// WHY THIS METRIC AND NOT THE SHORTER ONE
/// ============================================================================
///
/// The obvious choice is ΔE*ab (CIE 1976) — plain Euclidean distance in Lab —
/// and it is four lines instead of forty. It is also known to be badly
/// non-uniform: it overstates differences in the blue region and understates
/// them near the neutral axis, so the same numeric distance means very
/// different things depending on where in the space you measure it.
///
/// That is precisely the wrong failure for this app. Simulating dichromacy
/// collapses colours ONTO a blue-yellow axis, so every pair this file is asked
/// to judge after simulation lands in exactly the region ΔE*ab handles worst.
/// CIEDE2000 is the CIE's current recommendation and carries the corrections —
/// the lightness, chroma and hue weighting terms, plus the rotation term that
/// fixes the blue region specifically — that make a difference measured near
/// blue comparable with one measured near red.
///
/// It is still a MODEL of a laboratory judgement: two large, uniform, adjacent
/// patches, under controlled daylight, seen by an observer with typical colour
/// vision and time to look. A phone screen at unknown brightness, in unknown
/// light, showing small shapes that are moving, is none of those things. See
/// `test/palette_colourblind_test.dart` for what threshold is asked of it and
/// why that threshold is a judgement rather than a standard.
///
/// The parametric weights kL, kC and kH are all 1, the "reference conditions"
/// of the standard. Graphic-arts practice sometimes uses kL = 2; that would
/// make lightness differences count for half as much, which would be a way of
/// flattering a palette rather than testing it.
double deltaE2000(Lab one, Lab two) {
  const double kL = 1.0;
  const double kC = 1.0;
  const double kH = 1.0;

  final double c1 = math.sqrt(one.a * one.a + one.b * one.b);
  final double c2 = math.sqrt(two.a * two.a + two.b * two.b);
  final double cBar = (c1 + c2) / 2.0;

  // The chroma-dependent stretch of a*, which is what pulls near-neutral greys
  // apart so a small a* difference between two greys is not ignored.
  final double cBar7 = math.pow(cBar, 7).toDouble();
  final double g =
      0.5 * (1.0 - math.sqrt(cBar7 / (cBar7 + math.pow(25.0, 7).toDouble())));

  final double a1p = (1.0 + g) * one.a;
  final double a2p = (1.0 + g) * two.a;
  final double c1p = math.sqrt(a1p * a1p + one.b * one.b);
  final double c2p = math.sqrt(a2p * a2p + two.b * two.b);
  final double h1p = _hue(one.b, a1p);
  final double h2p = _hue(two.b, a2p);

  final double dLp = two.l - one.l;
  final double dCp = c2p - c1p;

  // Hue difference, taken the short way round the circle. Undefined — and
  // therefore zero — when either colour is exactly neutral, because a grey has
  // no hue to differ in.
  double dhp;
  if (c1p * c2p == 0.0) {
    dhp = 0.0;
  } else {
    dhp = h2p - h1p;
    if (dhp > 180.0) {
      dhp -= 360.0;
    } else if (dhp < -180.0) {
      dhp += 360.0;
    }
  }
  final double dHp = 2.0 * math.sqrt(c1p * c2p) * math.sin(_rad(dhp / 2.0));

  final double lBarP = (one.l + two.l) / 2.0;
  final double cBarP = (c1p + c2p) / 2.0;

  double hBarP;
  if (c1p * c2p == 0.0) {
    hBarP = h1p + h2p;
  } else if ((h1p - h2p).abs() <= 180.0) {
    hBarP = (h1p + h2p) / 2.0;
  } else if (h1p + h2p < 360.0) {
    hBarP = (h1p + h2p + 360.0) / 2.0;
  } else {
    hBarP = (h1p + h2p - 360.0) / 2.0;
  }

  final double t = 1.0 -
      0.17 * math.cos(_rad(hBarP - 30.0)) +
      0.24 * math.cos(_rad(2.0 * hBarP)) +
      0.32 * math.cos(_rad(3.0 * hBarP + 6.0)) -
      0.20 * math.cos(_rad(4.0 * hBarP - 63.0));

  final double dTheta =
      30.0 * math.exp(-math.pow((hBarP - 275.0) / 25.0, 2).toDouble());
  final double cBarP7 = math.pow(cBarP, 7).toDouble();
  final double rC =
      2.0 * math.sqrt(cBarP7 / (cBarP7 + math.pow(25.0, 7).toDouble()));

  final double sL = 1.0 +
      (0.015 * math.pow(lBarP - 50.0, 2).toDouble()) /
          math.sqrt(20.0 + math.pow(lBarP - 50.0, 2).toDouble());
  final double sC = 1.0 + 0.045 * cBarP;
  final double sH = 1.0 + 0.015 * cBarP * t;

  // The rotation term. This is the piece ΔE*ab has no equivalent of, and it is
  // what corrects the blue region — where dichromat simulations land.
  final double rT = -math.sin(_rad(2.0 * dTheta)) * rC;

  final double lTerm = dLp / (kL * sL);
  final double cTerm = dCp / (kC * sC);
  final double hTerm = dHp / (kH * sH);

  return math.sqrt(
    lTerm * lTerm + cTerm * cTerm + hTerm * hTerm + rT * cTerm * hTerm,
  );
}

/// ΔE₀₀ between two opaque sRGB colours. The everyday entry point.
double colourDifference(int a, int b) => deltaE2000(toLab(a), toLab(b));

// =============================================================================
// Dichromacy simulation
// =============================================================================

/// The two kinds of red-green colour blindness this app is checked against.
enum Dichromacy {
  /// No long-wavelength ("red") cone. About 1% of men.
  protanopia,

  /// No medium-wavelength ("green") cone. About 1% of men, and the most common
  /// dichromacy.
  deuteranopia,
}

/// What [argb] looks like to a dichromat of the given [type].
///
/// ============================================================================
/// THE MODEL, AND WHY SIMULATE RATHER THAN GUESS
/// ============================================================================
///
/// Guessing is the failure mode this replaces. "Green pipes on a green hill are
/// probably fine, they're different greens" is a sentence written by somebody
/// who can see both greens, about somebody who cannot, and it is wrong roughly
/// as often as it is right. A simulation replaces that sentence with a pair of
/// coordinates and a distance.
///
/// The method is Viénot, Brettel & Mollon (1999), which is the standard
/// single-projection construction for the two dichromacies below:
///
///   1. Encoded sRGB is linearised (real light, not gamma-encoded bytes).
///   2. Linear RGB is taken into LMS cone-response space with the
///      Smith-Pokorny fundamentals.
///   3. The missing cone's response is REPLACED by the value it would have had
///      for the nearest colour the dichromat cannot distinguish from this one —
///      which is a projection onto the plane spanned by the two surviving cone
///      responses. Protanopia loses L, deuteranopia loses M.
///   4. Back to linear RGB, then re-encoded.
///
/// Being a projection, it is idempotent: simulating twice is simulating once,
/// and `test/colour_math_test.dart` asserts exactly that. Greys come back
/// unchanged, because the achromatic axis already lies in the plane.
///
/// ============================================================================
/// WHAT THIS IS NOT
/// ============================================================================
///
/// * **It models DICHROMACY, the total absence of a cone class.** The far more
///   common conditions are protanomaly and deuteranomaly — a shifted cone, not
///   a missing one — which this says nothing about. Dichromacy is the harder
///   case, so passing here is evidence, not proof.
/// * **It says nothing about tritanopia**, blue-yellow loss, which needs the
///   full Brettel two-half-plane construction rather than one projection.
/// * **Out-of-gamut results are clipped.** The projection can land outside the
///   sRGB cube for saturated inputs, and clipping distorts those colours in a
///   direction the model does not account for.
/// * **It is a model of the SIGNAL, not of the EXPERIENCE.** It predicts which
///   colours become confusable. It predicts nothing about what a colourblind
///   player actually sees, how quickly they adapt, or whether the game is
///   pleasant to play. No colourblind player has tested this app.
int simulateDichromacy(int argb, Dichromacy type) {
  final double r = linearizeSrgb(redOf(argb) / 255.0);
  final double g = linearizeSrgb(greenOf(argb) / 255.0);
  final double b = linearizeSrgb(blueOf(argb) / 255.0);

  // Linear RGB -> LMS (Smith-Pokorny, as normalised for sRGB primaries by the
  // Viénot/Brettel implementations).
  final double l = 17.8824 * r + 43.5161 * g + 4.11935 * b;
  final double m = 3.45565 * r + 27.1554 * g + 3.86714 * b;
  final double s = 0.0299566 * r + 0.184309 * g + 1.46709 * b;

  // The projection. Exactly one coordinate is rewritten; the other two are the
  // cone responses the observer still has, and they are left alone.
  double lp = l;
  double mp = m;
  final double sp = s;
  switch (type) {
    case Dichromacy.protanopia:
      lp = 2.02344 * m - 2.52581 * s;
    case Dichromacy.deuteranopia:
      mp = 0.494207 * l + 1.24827 * s;
  }

  // LMS -> linear RGB.
  final double rr =
      0.0809444479 * lp - 0.130504409 * mp + 0.116721066 * sp;
  final double gg =
      -0.0102485335 * lp + 0.0540193266 * mp - 0.113614708 * sp;
  final double bb =
      -0.000365296938 * lp - 0.00412161469 * mp + 0.693511405 * sp;

  int byte(double linear) => (encodeSrgb(linear) * 255.0).round().clamp(0, 255);

  return packArgb(alphaOf(argb), byte(rr), byte(gg), byte(bb));
}
