/// Every colour in the game, in one place, so it can be ENUMERATED.
///
/// ============================================================================
/// WHY A PALETTE FILE RATHER THAN COLOURS WHERE THEY ARE USED
/// ============================================================================
///
/// Before this file the colours were `Color(0x...)` literals scattered through
/// `lib/main.dart` and `lib/ui/game_screens.dart`. Every one of them was
/// readable, and the set of them was not: nothing could ask "what colours does
/// this app use?", so nothing could answer "and do they all pass?". A test that
/// checks only the pairs somebody remembered to list is a test that goes green
/// the day somebody forgets.
///
/// So the colours moved here and the literals left. `test/palette_test.dart`
/// keeps it that way with a source scan: a hex colour literal anywhere in
/// `lib/main.dart` or `lib/ui/` outside this file fails the suite. That is the
/// mechanism behind "every pair the UI renders is reachable from the palette" —
/// not a convention, a check.
///
/// ============================================================================
/// WHAT THIS FILE CANNOT COVER, STATED UP FRONT
/// ============================================================================
///
/// The car and the pipes are drawn from `assets/sprites/miatasprite.png`. A PNG
/// is not a palette entry and cannot be made into one. Text is never drawn on
/// the sprite — the two surfaces that carry text over the playfield, [hudSurface]
/// and [cardSurface], are fully opaque precisely so that what passes behind them
/// cannot change what the text is read against — and
/// `test/palette_contrast_test.dart` asserts that opacity rather than assuming
/// it. The sprite's own colours are measured, from the actual file, in
/// `test/sprite_colours.dart`, and used there to check that the ghost car stays
/// distinguishable from the live one.
///
/// ============================================================================
/// PURE DART
/// ============================================================================
///
/// Colours are `int`s in 0xAARRGGBB rather than `Color`s, so this file and
/// `lib/ui/colour_math.dart` can be run by `tool/palette_report.dart` under a
/// bare `dart run` with no Flutter engine. `lib/main.dart` and
/// `lib/ui/game_screens.dart` do the one-line conversion.
library;

import 'package:flappymiata/ui/colour_math.dart';

// =============================================================================
// THE COLOURS
//
// Every `const int` below must also appear in [paletteColours]. That is checked
// by a source scan in `test/palette_test.dart`, because a colour that exists in
// the app but not in the list is a colour nothing grades.
// =============================================================================

// -- the world ----------------------------------------------------------------

/// What Flame clears the canvas to. Only ever seen for the frame or two before
/// the backdrop is drawn, and behind nothing else.
const int gameBackground = 0xFF10233F;

/// Top of the sky gradient.
const int skyTop = 0xFF173B62;

/// Bottom of the sky gradient, at the horizon.
const int skyBottom = 0xFF4C7E92;

/// The hills behind the playfield.
///
/// CHANGED, and this one did NOT fail on its own — say so plainly. As
/// `0xFF5F9B8A` it scored 17.04 ΔE₀₀ against [pipeBody] with normal colour
/// vision, 18.81 under deuteranopia and 16.89 under protanopia: over the bar,
/// but by under two units on a bar that is itself a judgement. It was changed
/// because it was the third member of a family of three greens, the other two
/// of which did fail outright — see [horizonBand] and [ground] — and one green
/// hill left standing between a grey verge and a grey road would have been a
/// scene held together by nothing. The blue-grey reads as haze and distance,
/// which is what a background hill is for.
const int hill = 0xFF5A7C9B;

/// The band along the top of the ground.
///
/// CHANGED BECAUSE IT FAILED. As `0xFF78A88D` it scored 12.09 ΔE₀₀ against
/// [pipeHighlight] normally, 12.37 under deuteranopia and 12.55 under
/// protanopia — all three under the 15 the game asks for. The pipes cross this
/// band on their way to the ground, so a player was being asked to pick a
/// bright green wall out of a muted green verge. Now 30.79 / 29.73 / 31.45.
const int horizonBand = 0xFF8C9BA8;

/// The clouds. Translucent, so the sky gradient shows through them.
const int cloud = 0xB8F4FBF4;

/// The ground.
///
/// CHANGED BECAUSE IT FAILED, and it was by far the worst pair in the game. As
/// `0xFF264B3D` — a dark green — against [pipeOutline]'s `0xFF153D2B` it scored
/// 5.09 ΔE₀₀ normally, 5.25 under deuteranopia and 5.16 under protanopia. The
/// bottom pipe is drawn straight over the ground, so the edge that decides
/// whether the car lives was a dark green line on a dark green field for
/// everybody, colourblind or not. An asphalt grey suits a car game and puts the
/// pair at 24.16 / 18.06 / 21.24.
const int ground = 0xFF3A3F52;

// -- the pipes ----------------------------------------------------------------
//
// The pipes keep their green. They are the thing the player must not hit, so
// when a green and a not-green had to be pulled apart, the green stayed on the
// obstacle and the scenery moved.

/// The dark edge every pipe is outlined in.
const int pipeOutline = 0xFF153D2B;

/// The body of a pipe.
const int pipeBody = 0xFF2D7A4A;

/// The lit edge down the left of a pipe.
const int pipeHighlight = 0xFF65B96C;

/// The shaded edge down the right of a pipe.
const int pipeShadow = 0xFF205A3A;

// -- the cars -----------------------------------------------------------------

/// The recorded best run's car: a hollow outline, drawn in this one colour.
///
/// RENAMED FROM `ghostSilhouette`, AND THE NAME IS THE POINT. It really was a
/// silhouette — the car sprite flattened to one flat colour — and a player
/// reported the obvious consequence: "it makes it really hard to see what's you
/// and what's the ghost." A silhouette is the car's exact outline filled in, so
/// no colour put inside it can stop it being a second car-shaped mass moving at
/// speed. The fill is gone; what is left is a stroke. See `_GhostLayer` in
/// `lib/main.dart` for the full argument.
///
/// THE ALPHA WENT UP WITH IT, `0x8C` -> `0xD9`, 55% to 85%, and that is a
/// consequence of the change rather than a separate opinion. A fill covers
/// thousands of pixels and can afford to be faint; a 3px stroke covers a few
/// hundred, and at 55% over a bright green pipe there would not be enough of
/// its own colour left to be told apart from one. The RGB did not move at all,
/// so every number below moved for exactly one reason.
///
/// MEASURED BOTH WAYS, normal / deuteranopia / protanopia, worst backdrop:
///
///   ghost vs a pipe      19.22 / 20.53 / 18.88   ->  27.63 / 29.54 / 27.27
///   ghost vs the sky     32.00 / 28.39 / 30.74   ->  51.92 / 48.02 / 51.56
///   ghost vs the live car, worst of four backdrops x three visions
///   (`test/palette_colourblind_test.dart`, measured off the real PNG):
///                                       19.02   ->  29.17
///
/// All three were already over the bar of 15 and all three went up. Worth being
/// blunt about what that does and does not mean: the pair that was actually
/// wrong — the ghost against the live car — scored 19.02 while a player could
/// not tell them apart. ΔE₀₀ is a distance between two colours, and the defect
/// was a shape. Colour was never going to fix it and these numbers were never
/// going to report it.
///
/// Still the same RGB as [panelBorder] — asserted in `test/palette_test.dart`,
/// so the two cannot drift apart while both claim to be "the game's teal" — and
/// still below full alpha, so the ghost reads as a thing being remembered
/// rather than a thing that is there.
const int ghostOutline = 0xD98BD3C7;

// -- assist mode --------------------------------------------------------------

/// The coasting path: where the car goes if nothing is tapped.
///
/// CHANGED BECAUSE IT FAILED, and it failed for everybody before it failed for
/// a dichromat. As `0x99FFFFFF` — white at 60% — it scored 8.61 ΔE₀₀ against
/// [assistWindow] with normal colour vision, 3.65 under deuteranopia and 2.14
/// under protanopia. Two point one is inside the range a laboratory calls
/// "barely telling them apart at all", for two lines drawn on top of each other
/// carrying different claims. The only thing separating them was stroke width.
///
/// AMBER, AND THE HUE IS THE POINT. Assist mode has three signals — this path,
/// the offered [assistWindow] and the [assistDeadline] — and both dichromacies
/// this app is checked against are losses along the red-green axis. So the
/// three signals are spread along the axis that SURVIVES: blue-yellow. Teal
/// sits at the blue end, amber at the yellow end, and the pink deadline is far
/// enough in lightness from both. Now 23.14 against the window and 25.10
/// against the deadline, worst case across every backdrop and both
/// simulations.
///
/// The alpha went from 60% to 90% in the same change. At 60% the line's own
/// colour was mostly whatever was behind it, which is another way of saying it
/// had no colour to be told apart by.
const int assistCoast = 0xE6FFD24A;

/// The offered flap window.
const int assistWindow = 0xE68BD3C7;

/// The last frame on which doing nothing is still survivable.
///
/// Teal means "you may tap here" and this means "tap before here", so the two
/// carry OPPOSITE advice and are the pair in this app it would cost a run to
/// confuse. Green-versus-red is the worst possible way to say that, which is
/// why it is not only a hue: the deadline is a single short cross-stroke and
/// the window is a thick line along the path, so the shapes differ too. The
/// colours are checked under both simulations all the same.
const int assistDeadline = 0xE6FF2D78;

// -- the collision-box overlay ------------------------------------------------
//
// Off in anything shipped (`kShowCollisionBoxes`), but graded anyway: the whole
// claim these three make is that a screenshot of the overlay can be read
// without a legend, and that claim is exactly a distinguishability claim.

/// The car's collision box.
const int debugCarBox = 0xFFFF2D78;

/// An obstacle's collision box.
const int debugObstacleBox = 0xFFFFC13B;

/// The centre line of a gap.
const int debugGapCentre = 0xFF3BE0FF;

// -- panels, screens and text -------------------------------------------------

/// The teal that outlines every panel in the game.
const int panelBorder = 0xFF8BD3C7;

/// The in-play HUD's backing.
///
/// FULLY OPAQUE, AND THAT IS THE POINT. It was `0xE812263D` — 91% — while the
/// comment beside it insisted the alpha byte "is `FF` and has to stay `FF`".
/// The code and the comment disagreed, and the code was wrong: pipes and the
/// car both pass behind this panel, so 9% of whatever was underneath was
/// mixing into the colour the score is read against, and the contrast of that
/// pair was a property of the frame rather than of the palette. At `FF` the
/// question has one answer and the test can state it.
const int hudSurface = 0xFF12263D;

/// The fill of a screen card, and of the pause button.
///
/// OPAQUE for the same reason as [hudSurface]. It was `0xF20A1D32`; the pause
/// button in particular sits over the live playfield with no scrim under it, so
/// its glyph was being read against 5% of a moving pipe.
const int cardSurface = 0xFF0A1D32;

/// A wash over the playfield while a screen is up.
///
/// Stays translucent on purpose: the pipes and the car have to stay visible
/// behind it, so a paused game still looks like the game. NO TEXT IS EVER DRAWN
/// ON THIS — every label on a screen sits on [cardSurface] — which is what makes
/// its translucency harmless.
const int scrim = 0xB3061224;

/// The fill of the primary button on a screen.
const int buttonFill = 0xFF17385C;

/// The fill of every other button: nothing at all, so the card shows through.
const int buttonPlainFill = 0x00000000;

/// Text.
const int ink = 0xFFFFFFFF;

/// Secondary text — labels and hints — dimmer so the numbers read first.
const int inkDim = 0xFFA8C4D8;

// =============================================================================
// The enumeration
// =============================================================================

/// One named colour, with what it is for.
class PaletteColour {
  /// The identifier it is declared under, so a failing test can name it.
  final String name;

  /// 0xAARRGGBB.
  final int argb;

  /// What it is used for, in one line.
  final String role;

  const PaletteColour(this.name, this.argb, this.role);

  @override
  String toString() => '$name ${hexOf(argb)}';
}

/// Every colour above, in one list.
///
/// The list and the constants are two spellings of the same fact, which is a
/// drift risk — so `test/palette_test.dart` reads this file's source and fails
/// if any `const int` is missing an entry here.
const List<PaletteColour> paletteColours = <PaletteColour>[
  PaletteColour('gameBackground', gameBackground, 'the cleared canvas'),
  PaletteColour('skyTop', skyTop, 'top of the sky gradient'),
  PaletteColour('skyBottom', skyBottom, 'sky at the horizon'),
  PaletteColour('hill', hill, 'the hills'),
  PaletteColour('horizonBand', horizonBand, 'the band above the ground'),
  PaletteColour('cloud', cloud, 'clouds, translucent over the sky'),
  PaletteColour('ground', ground, 'the ground'),
  PaletteColour('pipeOutline', pipeOutline, 'the dark edge of a pipe'),
  PaletteColour('pipeBody', pipeBody, 'the body of a pipe'),
  PaletteColour('pipeHighlight', pipeHighlight, 'the lit edge of a pipe'),
  PaletteColour('pipeShadow', pipeShadow, 'the shaded edge of a pipe'),
  PaletteColour('ghostOutline', ghostOutline, "the best run's car, outlined"),
  PaletteColour('assistCoast', assistCoast, 'the coasting path'),
  PaletteColour('assistWindow', assistWindow, 'the offered flap window'),
  PaletteColour('assistDeadline', assistDeadline, 'the tap-by-here mark'),
  PaletteColour('debugCarBox', debugCarBox, "the car's collision box"),
  PaletteColour('debugObstacleBox', debugObstacleBox, 'an obstacle box'),
  PaletteColour('debugGapCentre', debugGapCentre, 'the centre of a gap'),
  PaletteColour('panelBorder', panelBorder, 'the outline of every panel'),
  PaletteColour('hudSurface', hudSurface, 'the in-play HUD backing'),
  PaletteColour('cardSurface', cardSurface, 'a screen card, and the pause key'),
  PaletteColour('scrim', scrim, 'the wash over a stopped playfield'),
  PaletteColour('buttonFill', buttonFill, 'the primary button'),
  PaletteColour('buttonPlainFill', buttonPlainFill, 'every other button'),
  PaletteColour('ink', ink, 'text'),
  PaletteColour('inkDim', inkDim, 'secondary text'),
];

/// Every opaque colour a translucent overlay can end up sitting on.
///
/// Used as the set of worst cases wherever something translucent has to be
/// judged: the assist lines, the ghost, the scrim. Only the OPAQUE entries,
/// because a backdrop that is itself see-through is not a backdrop — plus the
/// cloud flattened onto the sky, which is the brightest thing the playfield can
/// actually show.
const List<int> playfieldBackdrops = <int>[
  gameBackground,
  skyTop,
  skyBottom,
  hill,
  horizonBand,
  ground,
  pipeOutline,
  pipeBody,
  pipeHighlight,
  pipeShadow,
];

/// The clouds as they actually appear: [cloud] laid over the top of the sky.
int get cloudOnSky => composite(cloud, skyTop);

// =============================================================================
// Text pairs
// =============================================================================

/// One pair of colours the reader has to be able to tell apart, with the
/// backgrounds already flattened.
class TextPair {
  /// Where in the app this pair appears, so a failure names a screen.
  final String where;

  /// The colour of the glyphs. Always opaque.
  final int foreground;

  /// What is behind them. Always opaque — flatten first if it is not.
  final int background;

  /// True when this is a border, a glyph outline or another non-text control
  /// and is therefore graded at [wcagAaNonTextContrast] rather than
  /// [wcagAaTextContrast].
  final bool nonText;

  const TextPair(this.where, this.foreground, this.background,
      {this.nonText = false});

  /// The bar this pair has to clear.
  double get required =>
      nonText ? wcagAaNonTextContrast : wcagAaTextContrast;

  /// What it actually scores.
  double get ratio => contrastRatio(foreground, background);

  /// Whether it clears the bar. Compared with a tolerance of zero: 4.499 is a
  /// fail, and rounding it up in a report would be the whole problem.
  bool get passes => ratio >= required;
}

/// The surface a screen card presents to its text.
///
/// [cardSurface] is opaque, so the scrim and the playfield beneath it cannot
/// reach the text. Written as a flatten anyway rather than as the constant, so
/// that if anybody ever makes the card translucent again this value — and every
/// ratio derived from it — moves on its own instead of staying quietly wrong.
int get screenCardOverPlayfield => flatten(
      brightestPlayfield,
      <int>[scrim, cardSurface],
    );

/// The same card over the darkest thing the playfield can show.
int get screenCardOverDarkPlayfield => flatten(
      darkestPlayfield,
      <int>[scrim, cardSurface],
    );

/// The primary button's fill, as seen on a card.
int get primaryButtonSurface =>
    composite(buttonFill, screenCardOverPlayfield);

/// The pause button's fill, which sits on the LIVE playfield with no scrim.
int get pauseButtonSurface => composite(cardSurface, brightestPlayfield);

/// The HUD panel's backing, over the playfield.
int get hudPanelSurface => composite(hudSurface, brightestPlayfield);

/// The brightest opaque colour the playfield can show.
int get brightestPlayfield => _extremePlayfield(brightest: true);

/// The darkest opaque colour the playfield can show.
int get darkestPlayfield => _extremePlayfield(brightest: false);

int _extremePlayfield({required bool brightest}) {
  int best = playfieldBackdrops.first;
  double bestL = relativeLuminance(best);
  for (final int c in <int>[...playfieldBackdrops, cloudOnSky]) {
    final double l = relativeLuminance(c);
    if (brightest ? l > bestL : l < bestL) {
      best = c;
      bestL = l;
    }
  }
  return best;
}

/// Every text/background pair the app renders, with the stack already
/// flattened.
///
/// A DECLARED LIST IS THE WEAKER HALF OF THE CHECK and is only half the story.
/// The other half is in `test/palette_contrast_test.dart`, which builds each
/// screen for real, walks the element tree, and grades whatever text it finds
/// against whatever is actually behind it. This list is what
/// `tool/palette_report.dart` prints and what covers the two places a widget
/// crawl cannot reach: the HUD, whose text is drawn straight onto the Flame
/// canvas, and the pause button, which sits on the live playfield.
List<TextPair> get textPairs => <TextPair>[
      TextPair('HUD score/risk/best readout', ink, hudPanelSurface),
      TextPair('HUD panel border', panelBorder, hudPanelSurface,
          nonText: true),
      TextPair('screen title and score numbers', ink, screenCardOverPlayfield),
      TextPair('screen labels and hints', inkDim, screenCardOverPlayfield),
      TextPair('primary button label', ink, primaryButtonSurface),
      TextPair('plain button label', ink, screenCardOverPlayfield),
      TextPair('NEW BEST banner', panelBorder, screenCardOverPlayfield),
      TextPair('card border against the card', panelBorder,
          screenCardOverPlayfield,
          nonText: true),
      TextPair('card border against the scrim outside it', panelBorder,
          composite(scrim, brightestPlayfield),
          nonText: true),
      TextPair('pause glyph', ink, pauseButtonSurface),
      TextPair('pause button border', panelBorder, pauseButtonSurface,
          nonText: true),
      // The same three cards again over the DARKEST the playfield goes. With
      // opaque surfaces these are identical to the entries above, which is the
      // point: the pair stops depending on the frame.
      TextPair('screen title, dark playfield behind', ink,
          screenCardOverDarkPlayfield),
      TextPair('screen labels, dark playfield behind', inkDim,
          screenCardOverDarkPlayfield),
    ];

/// Every surface that carries text. All of them must be opaque — see
/// [hudSurface].
const List<PaletteColour> textBearingSurfaces = <PaletteColour>[
  PaletteColour('hudSurface', hudSurface, 'the in-play HUD backing'),
  PaletteColour('cardSurface', cardSurface, 'a screen card, and the pause key'),
  PaletteColour('buttonFill', buttonFill, 'the primary button'),
];

// =============================================================================
// Pairs that must stay TELLABLE APART
// =============================================================================

/// Two colours the game relies on the player being able to distinguish, and
/// what goes wrong if they cannot.
class DistinctPair {
  /// What the two things are.
  final String label;

  /// What the player gets wrong when these merge. Written out because a
  /// distinguishability requirement with no consequence attached is a
  /// preference, not a requirement.
  final String cost;

  /// The first colour. May be translucent.
  final int a;

  /// The second. May be translucent.
  final int b;

  /// The opaque backgrounds both are seen against. The pair is graded against
  /// every one of them and scored by the WORST.
  final List<int> over;

  const DistinctPair(this.label, this.cost, this.a, this.b, this.over);

  /// The smallest ΔE₀₀ between the two across every backdrop, under [type] —
  /// or under normal colour vision when [type] is null.
  double worstDifference(Dichromacy? type) {
    double worst = double.infinity;
    for (final int backdrop in over) {
      int flat(int c) {
        final int on = composite(c, backdrop);
        return type == null ? on : simulateDichromacy(on, type);
      }

      final double d = colourDifference(flat(a), flat(b));
      if (d < worst) worst = d;
    }
    return worst;
  }

  /// Which backdrop produced [worstDifference].
  int worstBackdrop(Dichromacy? type) {
    int best = over.first;
    double worst = double.infinity;
    for (final int backdrop in over) {
      int flat(int c) {
        final int on = composite(c, backdrop);
        return type == null ? on : simulateDichromacy(on, type);
      }

      final double d = colourDifference(flat(a), flat(b));
      if (d < worst) {
        worst = d;
        best = backdrop;
      }
    }
    return best;
  }
}

/// The threshold a [DistinctPair] must clear, in ΔE₀₀.
///
/// ============================================================================
/// THIS NUMBER IS A JUDGEMENT, UNLIKE 4.5:1
/// ============================================================================
///
/// [wcagAaTextContrast] is a published standard and is not ours to move. There
/// is no equivalent standard for "these two game elements must be tellable
/// apart", so this is a chosen number and it is worth being explicit about how
/// it was chosen rather than pretending otherwise.
///
/// ΔE₀₀ = 1.0 is the classical just-noticeable difference: two large uniform
/// patches, touching, under controlled light, with an unhurried observer. Every
/// one of those conditions is false here. The things being compared are small,
/// separated across the screen, moving at half a screen width per second, on an
/// uncalibrated phone in unknown lighting, seen by somebody with about a
/// sixtieth of a second to decide. No published multiplier covers that gap.
///
/// 15 is the multiplier taken, and it is deliberately far above the JND rather
/// than a hair over it — the failure being guarded against is a player flying
/// into a wall, and the cost of demanding too much is that some scenery gets
/// recoloured. `test/palette_colourblind_test.dart` reports the actual margins,
/// which are mostly well clear of this, so the exact value of the threshold is
/// not what any verdict rests on.
const double distinguishableDeltaE = 15.0;

/// Every pair the game needs the player to tell apart.
List<DistinctPair> get distinctPairs => <DistinctPair>[
      const DistinctPair(
        'pipe body vs the hills',
        'a pipe is a wall and a hill is scenery; merging them means flying '
            'into a wall that looked like background',
        pipeBody,
        hill,
        <int>[hill],
      ),
      const DistinctPair(
        'pipe body vs the ground',
        'the bottom pipe is drawn straight over the ground, so a merge hides '
            'where the gap ends',
        pipeBody,
        ground,
        <int>[ground],
      ),
      const DistinctPair(
        'pipe body vs the horizon band',
        'same as the hills: the pipes cross this band on their way down',
        pipeBody,
        horizonBand,
        <int>[horizonBand],
      ),
      const DistinctPair(
        'pipe highlight vs the hills',
        'the lit edge is what gives a pipe its shape at speed',
        pipeHighlight,
        hill,
        <int>[hill],
      ),
      const DistinctPair(
        'pipe highlight vs the horizon band',
        'the lit edge again, against the brightest scenery',
        pipeHighlight,
        horizonBand,
        <int>[horizonBand],
      ),
      const DistinctPair(
        'pipe outline vs the ground',
        "the pipe's dark edge is the boundary the collision test actually "
            'uses; losing it against the ground loses the edge of the gap',
        pipeOutline,
        ground,
        <int>[ground],
      ),
      const DistinctPair(
        'assist window vs assist deadline',
        'the two carry OPPOSITE advice — "you may tap here" and "tap before '
            'here" — so confusing them costs the run',
        assistWindow,
        assistDeadline,
        playfieldBackdrops,
      ),
      const DistinctPair(
        'assist window vs the coast path',
        'the thick line is a proved offer and the thin one is only a '
            'prediction; they must not read as one line',
        assistWindow,
        assistCoast,
        playfieldBackdrops,
      ),
      const DistinctPair(
        'assist deadline vs the coast path',
        'the third side of the same triangle — three signals means three '
            'pairs, and checking two of them would leave one unchecked',
        assistDeadline,
        assistCoast,
        playfieldBackdrops,
      ),
      const DistinctPair(
        'ghost car vs a pipe',
        'the ghost flies over the pipes; if it disappears into one there is '
            'nothing to race',
        ghostOutline,
        pipeBody,
        <int>[pipeBody],
      ),
      const DistinctPair(
        'ghost car vs the sky',
        'the same, for the two thirds of the screen that are sky',
        ghostOutline,
        skyTop,
        <int>[skyTop, skyBottom],
      ),
      const DistinctPair(
        'collision overlay: car box vs obstacle box',
        'the overlay claims a screenshot of it can be read without a legend, '
            'which is exactly a distinguishability claim',
        debugCarBox,
        debugObstacleBox,
        <int>[skyTop, pipeBody, ground],
      ),
      const DistinctPair(
        'collision overlay: car box vs gap centre',
        'as above',
        debugCarBox,
        debugGapCentre,
        <int>[skyTop, pipeBody, ground],
      ),
      const DistinctPair(
        'collision overlay: obstacle box vs gap centre',
        'as above',
        debugObstacleBox,
        debugGapCentre,
        <int>[skyTop, pipeBody, ground],
      ),
    ];
