/// The SHAPE of the car's collision box, as opposed to how it behaves.
///
/// WHY THIS IS A SEPARATE FILE FROM `game_model_test.dart`:
///
/// Everything in that file is a statement about the RULES — gravity
/// accumulates, a flap assigns rather than adds, an obstacle scores once. Not
/// one of those assertions can see a pixel, and that is deliberate: the model
/// is normalised so that it never has to know how big the screen is.
///
/// The assertions here are the exception that proves it. A normalised
/// coordinate system is screen-independent in POSITION and screen-DEPENDENT in
/// SHAPE — the renderer scales x by the screen width and y by the screen height,
/// two different numbers, so `0.10 wide by 0.05 tall` draws as a box taller
/// than it is wide on a phone and wider than it is tall on a square display.
/// Nothing inside the model can notice, because collision is tested in
/// normalised coordinates where a box is exactly what its numbers say.
///
/// That coupling is what let the car sprite be drawn 2.93x wider than the box
/// it was supposed to occupy, with the nose and tail passing through pipes
/// untouched. `GameModel.referenceAspect` is the fix: it names the screen the
/// boxes are designed against, so the shape becomes a stated assumption instead
/// of an accidental one. These tests hold that assumption still.
///
/// THEY PIN RELATIONSHIPS, NOT NUMBERS, and that distinction is the whole
/// value of the file. `expect(GameModel.carWidth, 0.164185)` would pass just as
/// happily if somebody deleted the derivation and typed the answer in — which
/// is precisely the mistake this is here to prevent, since a typed-in width
/// stops tracking `carSpriteAspect` the moment the artwork is re-exported.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/game/game_model.dart';

/// A screen at exactly `GameModel.referenceAspect`. The width is arbitrary —
/// every assertion below is a ratio or is compared against an area measured on
/// this same width — and 1080 is chosen only because it is the device the
/// original mismatch was measured on, so the numbers in the failure messages
/// match the numbers in the commit that caused all this.
const double referenceWidthPx = 1080.0;

/// The matching height, DERIVED rather than typed as 2400, so that changing
/// `GameModel.referenceAspect` moves this test's idea of the screen with it
/// instead of silently leaving it testing a screen the model no longer targets.
final double referenceHeightPx = referenceWidthPx * GameModel.referenceAspect;

/// The car's collision box in pixels on that reference screen.
///
/// Built from `GameModel.carBoxAt` rather than from the constants directly, so
/// this measures the box the collision code actually uses. A box assembled here
/// out of `carWidth` and `carHeight` would keep agreeing with itself even if
/// `carBoxAt` started halving one of them.
({double width, double height}) referenceCarBoxPx() {
  final Box box = GameModel.carBoxAt(0.5);
  return (
    width: (box.right - box.left) * referenceWidthPx,
    height: (box.bottom - box.top) * referenceHeightPx,
  );
}

void main() {
  group('car box shape', () {
    test('carWidth is derived from the sprite and the reference aspect, not '
        'typed in', () {
      // THE RELATIONSHIP, asserted as an identity rather than against a
      // literal. Written as the same expression in the same order as the
      // constant's own initialiser, so floating-point equality is exact and
      // there is no tolerance for a wrong answer to hide inside.
      //
      // What this catches that a literal would not: somebody replacing the
      // derivation with `static const double carWidth = 0.164185;`. That is a
      // real hazard rather than a hypothetical one — it looks like a
      // simplification, it keeps every other test in the suite green, and it
      // quietly severs the box from the artwork, so the next time the sprite is
      // re-exported at different proportions the hitbox stops matching it and
      // nothing says so.
      expect(
        GameModel.carWidth,
        GameModel.carHeight *
            GameModel.referenceAspect *
            GameModel.carSpriteAspect,
      );

      // And the inputs are the things they claim to be. Without these two, both
      // aspects could be set to 1.0 and the identity above would still hold —
      // it would just be asserting that carWidth equals carHeight, which is the
      // near-square box the whole exercise was about getting rid of.
      expect(GameModel.referenceAspect, 2400 / 1080);
      expect(
        GameModel.carSpriteAspect,
        286 / 120,
        reason: 'assets/sprites/miatasprite.png is 286 x 120, cropped to its '
            'opaque bounds',
      );
    });

    test('at the reference aspect the hitbox is the same shape as the sprite',
        () {
      final box = referenceCarBoxPx();

      // THE POINT OF THE WHOLE CHANGE. The sprite is drawn into this box, so
      // the box has to come out at the sprite's proportions ON SCREEN or the
      // car overhangs it — which is exactly what was happening before, at
      // 2.93x on the horizontal.
      expect(
        box.width / box.height,
        closeTo(GameModel.carSpriteAspect, 1e-9),
        reason: 'hitbox draws ${box.width} x ${box.height} px at the reference '
            'aspect; the sprite is ${GameModel.carSpriteAspect} : 1',
      );

      // Stated in absolute terms too, because "the ratio is right" is satisfied
      // by a box of any size and someone reading a failure deserves to see the
      // pixels. Observed for the current constants: 177.3 x 74.4.
      expect(box.width, closeTo(177.3, 0.5));
      expect(box.height, closeTo(74.4, 0.5));

      // The box is wider than it is tall, spelled out separately. The old
      // constants produced 108 x 120 — taller than wide, for a car two and a
      // third times longer than it is high — and no assertion in the suite
      // objected. One does now.
      expect(box.width, greaterThan(box.height));
    });

    test('the hitbox covers the same area as the box it replaced, so '
        'difficulty did not move', () {
      // The previous constants were carWidth 0.10 and carHeight 0.05, which is
      // 108 x 120 px on this screen. Written as the product of the two measured
      // pixel dimensions rather than as `12960` so the arithmetic is visible.
      const double previousAreaPx = 108.0 * 120.0;

      final box = referenceCarBoxPx();
      final double areaPx = box.width * box.height;

      // WHY AREA IS THE RIGHT INVARIANT AND WIDTH IS NOT: the box deliberately
      // changed shape — much wider, much shorter — because that is what makes
      // it match the car. Asserting either dimension held steady would forbid
      // the fix. What must NOT change without somebody deciding it should is
      // how much of the screen the car occupies, because that is what sets how
      // often a run ends. 5% is tight enough that a real re-tuning trips it and
      // loose enough that this does not fail on the rounding in 0.031.
      //
      // Measured for the current constants: 13193 px^2, 1.8% above the old box.
      expect(
        areaPx,
        closeTo(previousAreaPx, previousAreaPx * 0.05),
        reason: 'car hitbox now covers $areaPx px^2 against the previous '
            '$previousAreaPx; a change this large is a difficulty change and '
            'has to be a deliberate one',
      );
    });

    test('a gap still admits the car with room to spare', () {
      // The consequence of the reshape, checked in the units that decide
      // whether the game is playable at all: the gap has to be tall enough to
      // fly a car through, and the car has to be narrow enough that the danger
      // window is not the whole screen.
      //
      // This is a sanity bound, not a tuning assertion — it is deliberately
      // loose, and it exists so that a future edit to `carHeight` that makes
      // the game unplayable fails here rather than on a phone.
      expect(GameModel.gapHeight / GameModel.carHeight, greaterThan(4.0));

      // The time the car spends level with a pipe. 0.72s for these constants,
      // up from 0.58s, because the box really is wider now.
      final double dangerWindow =
          (GameModel.carWidth + GameModel.obstacleWidth) /
              GameModel.scrollSpeed;
      expect(dangerWindow, closeTo(0.72, 0.05));

      // And the car still fits between the pipes horizontally with the whole
      // approach to spare — a car wider than the spacing could never be clear
      // of every obstacle at once.
      expect(GameModel.carWidth, lessThan(GameModel.obstacleSpacing));
    });
  });
}
