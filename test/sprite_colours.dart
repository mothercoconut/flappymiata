/// The car sprite's actual colours, measured from the actual PNG.
///
/// ============================================================================
/// WHY THIS EXISTS AND WHY IT IS NOT IN THE PALETTE
/// ============================================================================
///
/// `assets/sprites/miatasprite.png` is a picture. It has 34,320 pixels and no
/// name, so it cannot be a palette entry, and any claim about "the car's
/// colour" that was typed into a source file by hand would be a claim about
/// what somebody remembered the car looking like.
///
/// The honest alternative is to open the file and look. This decodes the sprite
/// at test time and reports what is really in it: the darkest and brightest
/// opaque pixels, which bound anything drawn over the car, and the mean of the
/// opaque pixels, which is the colour the car reads as at a glance and is what
/// the ghost silhouette has to stay distinguishable from.
///
/// Two consequences worth stating:
///
///   * These numbers move if the artist changes the sprite. That is the point.
///     A hard-coded "the car is red" would go on being asserted after somebody
///     shipped a blue one.
///   * `tool/palette_report.dart` cannot use any of this, because decoding a
///     PNG needs a Flutter engine and the tool deliberately runs under a bare
///     `dart run`. The sprite therefore appears in the tests and not in the
///     printed table, and that gap is named in the report rather than left for
///     a reader to notice.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show ByteData, rootBundle;

import 'package:flappymiata/ui/colour_math.dart';

/// The alpha at or above which a pixel counts as the car rather than as the
/// car's antialiased edge.
///
/// NOT 255, AND THAT IS A MEASURED FACT ABOUT THE FILE rather than a fudge.
/// `miatasprite.png`'s alpha channel tops out at 254 — whatever exported it
/// never wrote a fully opaque byte — so a strict `== 255` test finds nothing at
/// all in it, which is exactly what the first version of this file did before
/// somebody looked. [SpriteColours.maxAlpha] carries the real maximum so a test
/// can assert the property rather than trusting this paragraph.
const int spriteOpaqueThreshold = 250;

/// What was found in the sprite.
class SpriteColours {
  /// How many pixels are opaque enough to count. The PNG is largely transparent
  /// padding, so this is much smaller than its pixel count — and a number worth
  /// reporting, because a measurement taken over three pixels would be a
  /// measurement of nothing.
  final int opaquePixels;

  /// The largest alpha byte anywhere in the file.
  final int maxAlpha;

  /// The darkest fully opaque pixel, by WCAG relative luminance.
  final int darkest;

  /// The brightest fully opaque pixel.
  final int brightest;

  /// The mean of every fully opaque pixel, averaged in LINEAR light rather than
  /// in encoded bytes.
  ///
  /// Averaging gamma-encoded bytes is the classic way to get a mean that is too
  /// dark: the encoding is not linear in light, so the arithmetic mean of two
  /// encoded values is not the encoding of the mean light. This averages the
  /// light and re-encodes once at the end.
  final int mean;

  const SpriteColours({
    required this.opaquePixels,
    required this.maxAlpha,
    required this.darkest,
    required this.brightest,
    required this.mean,
  });

  @override
  String toString() => 'SpriteColours($opaquePixels opaque px, '
      'max alpha $maxAlpha, darkest ${hexOf(darkest)}, '
      'brightest ${hexOf(brightest)}, mean ${hexOf(mean)})';
}

/// Decodes [assetKey] and measures it.
///
/// Only pixels at or above [spriteOpaqueThreshold] count. A substantially
/// transparent pixel is a blend of the car and whatever is behind it, so its
/// colour is not a fact about the car — and the antialiased rim of a sprite is
/// full of them, which would drag every number here toward the background of
/// whatever happened to be underneath.
///
/// The bytes come back PREMULTIPLIED — `rawRgba` means each channel has already
/// been scaled by the alpha — so they are divided back out before anything is
/// measured. At alpha 254 that is a 0.4% correction and would not change a
/// verdict; it is done anyway, because a measurement that is quietly 0.4% wrong
/// for a reason nobody wrote down is a measurement somebody will one day take
/// at face value at alpha 128.
Future<SpriteColours> measureSprite([
  String assetKey = 'assets/sprites/miatasprite.png',
]) async {
  final ByteData data = await rootBundle.load(assetKey);
  final ui.Codec codec =
      await ui.instantiateImageCodec(data.buffer.asUint8List());
  final ui.Image image = (await codec.getNextFrame()).image;
  final ByteData? raw =
      await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  codec.dispose();
  image.dispose();
  if (raw == null) {
    throw StateError('could not read the pixels of $assetKey');
  }

  final Uint8List bytes = raw.buffer.asUint8List();
  int count = 0;
  int maxAlpha = 0;
  int darkest = 0xFFFFFFFF;
  int brightest = 0xFF000000;
  double darkestL = double.infinity;
  double brightestL = -1.0;
  double sumR = 0.0;
  double sumG = 0.0;
  double sumB = 0.0;

  for (int i = 0; i + 3 < bytes.length; i += 4) {
    final int a = bytes[i + 3];
    if (a > maxAlpha) maxAlpha = a;
    if (a < spriteOpaqueThreshold) continue;

    int straight(int premultiplied) =>
        (premultiplied * 255 / a).round().clamp(0, 255);

    final int r = straight(bytes[i]);
    final int g = straight(bytes[i + 1]);
    final int b = straight(bytes[i + 2]);
    final int argb = packArgb(0xFF, r, g, b);
    count++;
    final double l = relativeLuminance(argb);
    if (l < darkestL) {
      darkestL = l;
      darkest = argb;
    }
    if (l > brightestL) {
      brightestL = l;
      brightest = argb;
    }
    sumR += linearizeSrgb(r / 255.0);
    sumG += linearizeSrgb(g / 255.0);
    sumB += linearizeSrgb(b / 255.0);
  }

  if (count == 0) {
    throw StateError('$assetKey has no pixel at alpha '
        '$spriteOpaqueThreshold or above; the most opaque is $maxAlpha');
  }

  int channel(double sum) =>
      (encodeSrgb(sum / count) * 255.0).round().clamp(0, 255);

  return SpriteColours(
    opaquePixels: count,
    maxAlpha: maxAlpha,
    darkest: darkest,
    brightest: brightest,
    mean: packArgb(0xFF, channel(sumR), channel(sumG), channel(sumB)),
  );
}
