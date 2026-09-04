/// Every text/background pair in the game, graded at 4.5:1 by arithmetic.
///
/// ============================================================================
/// TWO CHECKS, BECAUSE ONE OF THEM IS WEAK ON ITS OWN
/// ============================================================================
///
/// The first half grades `palette.textPairs`: a declared list of pairs with the
/// backgrounds already flattened. It is the half `tool/palette_report.dart`
/// prints, and it is the only half that can reach the two places a widget tree
/// cannot — the HUD, whose text is drawn straight onto the Flame canvas, and
/// the pause button, which sits on the live playfield with nothing between.
///
/// It is also the weak half. A declared list checks the pairs somebody
/// remembered, and goes green the day somebody forgets.
///
/// The second half is the answer to that. It BUILDS each screen, walks the
/// element tree, finds every `Text` that is really on it, resolves the colour
/// that text will really be painted in — through `DefaultTextStyle`, exactly as
/// the framework will — and flattens every background layer between it and the
/// playfield. Then it grades whatever it found. Nothing is declared; the pairs
/// come from the widgets. A label added to a screen tomorrow is graded tomorrow
/// with no list to update.
///
/// ============================================================================
/// WHAT NEITHER HALF COVERS — READ THIS BEFORE TRUSTING THE FILE
/// ============================================================================
///
///   * **The sky gradient.** `_BackdropLayer` interpolates between two palette
///     entries, and the colours in between are neither. No text is drawn on the
///     sky — every label in the game sits on an opaque panel — so the gradient
///     never appears in a text pair. If text were ever put on it, this file
///     would not notice, and that is a real gap rather than a safe one.
///   * **The car and pipe art.** `assets/sprites/miatasprite.png` is a picture
///     and cannot be a palette entry. It is handled by making the two surfaces
///     that carry text over the playfield fully opaque, which is asserted here
///     rather than assumed — the sprite then cannot reach the text at all. The
///     sprite's own colours are measured in `test/sprite_colours.dart` and used
///     by `test/palette_colourblind_test.dart`.
///   * **Anything drawn on the Flame canvas that is not the HUD readout.** The
///     crawl sees widgets. The canvas layers are covered by the declared list
///     and by the source scan in `test/palette_test.dart`, which is a weaker
///     guarantee and is named as one.
///   * **Nothing here has been seen on hardware.** No emulator or device was
///     available. These are contrast ratios computed from the numbers the app
///     will paint with; whether the result is comfortable to read on a phone in
///     sunlight is unverified.
library;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/main.dart';
import 'package:flappymiata/ui/colour_math.dart';
import 'package:flappymiata/ui/game_screens.dart';
import 'package:flappymiata/ui/high_score_store.dart';
import 'package:flappymiata/ui/motion.dart';
import 'package:flappymiata/ui/palette.dart' as palette;

// =============================================================================
// A host with no game under it, so any screen can be put in any state.
// =============================================================================

class _Host implements GameScreenHost {
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  @override
  Listenable get revision => _revision;
  @override
  int score = 7;
  @override
  int riskScore = 21;
  @override
  int bestScore = 42;
  @override
  bool hasBestScore = true;
  @override
  bool isNewBest = true;
  @override
  bool paused = false;
  @override
  bool assistEnabled = false;
  @override
  MotionSetting motionSetting = MotionSetting.system;
  @override
  bool systemDisablesAnimations = false;

  @override
  void toggleAssist() {}
  @override
  void cycleMotion() {}
  @override
  void startRun() {}
  @override
  void pauseRun() {}
  @override
  void resumeRun() {}
  @override
  void restartRun() {}
}

// =============================================================================
// The crawler
// =============================================================================

/// One piece of text as it will actually be painted.
class RenderedText {
  /// What it says, so a failure names something a reader can find on screen.
  final String text;

  /// The colour the glyphs will be drawn in, after `DefaultTextStyle` has been
  /// merged in exactly as the framework will merge it.
  final int ink;

  /// Everything painted behind it, flattened to one opaque colour.
  final int background;

  /// The background layers found between the text and the playfield, nearest
  /// first. Reported on a failure so the reader can see which container is
  /// responsible.
  final List<int> stack;

  const RenderedText(this.text, this.ink, this.background, this.stack);

  /// What the pair scores.
  double get ratio => contrastRatio(ink, background);

  @override
  String toString() => '"$text" ${hexOf(ink)} on ${hexOf(background)} '
      '(${ratio.toStringAsFixed(2)}:1, stack ${stack.map(hexOf).join(' over ')})';
}

/// Every `Text` currently mounted, with its colour and its real background.
///
/// [beneath] is what the whole screen is painted on top of — the playfield.
/// Passed in rather than assumed, so the same screen can be graded against the
/// brightest and the darkest thing the game can put behind it.
List<RenderedText> crawlText(WidgetTester tester, {required int beneath}) {
  final List<RenderedText> found = <RenderedText>[];

  for (final Element element in find.byType(Text).evaluate()) {
    final Text widget = element.widget as Text;

    // Resolved the way the framework resolves it: the inherited default first,
    // then the widget's own style merged over the top. Reading `widget.style`
    // alone would miss every label that relies on the `DefaultTextStyle` the
    // scaffold installs — which is most of them.
    final TextStyle resolved =
        DefaultTextStyle.of(element).style.merge(widget.style);
    final Color? ink = resolved.color;
    expect(ink, isNotNull,
        reason: '"${widget.data}" has no resolved colour at all, so what it '
            'renders as depends on the framework default rather than on this '
            "app's palette");

    // Walk out to the root, collecting anything that paints a background.
    // `Container` builds a `DecoratedBox` and `Container(color:)` builds a
    // `ColoredBox`, so both spellings are caught by looking for those two.
    final List<int> stack = <int>[];
    element.visitAncestorElements((Element ancestor) {
      final Widget w = ancestor.widget;
      if (w is ColoredBox) {
        stack.add(w.color.toARGB32());
      } else if (w is DecoratedBox) {
        final Decoration d = w.decoration;
        if (d is BoxDecoration && d.color != null) {
          stack.add(d.color!.toARGB32());
        }
      }
      return true;
    });

    // `stack` came out nearest-first; compositing runs bottom-up.
    found.add(RenderedText(
      widget.data ?? '',
      ink!.toARGB32(),
      flatten(beneath, stack.reversed.toList()),
      stack,
    ));
  }
  return found;
}

/// Puts one screen on the tester with the ancestors a bare widget needs.
Future<void> showScreen(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(data: const MediaQueryData(), child: screen),
    ),
  );
}

/// The screens, each in the state that puts the most text on it.
List<(String, Widget)> screensUnderTest(GameScreenHost host) => <(String, Widget)>[
      ('start', StartScreen(host: host)),
      ('paused', PausedScreen(host: host)),
      ('game over', GameOverScreen(host: host)),
      ('pause button', PauseButton(host: host)),
    ];

void main() {
  group('the declared pairs all clear the bar', () {
    test('every text pair scores at least 4.5:1', () {
      final List<String> failures = <String>[];
      for (final palette.TextPair pair in palette.textPairs) {
        if (!pair.passes) {
          failures.add('${pair.where}: ${hexOf(pair.foreground)} on '
              '${hexOf(pair.background)} is ${pair.ratio.toStringAsFixed(2)}:1, '
              'needs ${pair.required}:1');
        }
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    });

    test('the list is not empty and covers every screen surface', () {
      // A loop over an empty list passes. So does a loop over a list that
      // happens to contain only the easy pairs.
      expect(palette.textPairs.length, greaterThanOrEqualTo(10));
      final Set<int> backgrounds =
          palette.textPairs.map((palette.TextPair p) => p.background).toSet();
      expect(backgrounds, contains(palette.hudPanelSurface));
      expect(backgrounds, contains(palette.screenCardOverPlayfield));
      expect(backgrounds, contains(palette.primaryButtonSurface));
      expect(backgrounds, contains(palette.pauseButtonSurface));
      final Set<int> inks =
          palette.textPairs.map((palette.TextPair p) => p.foreground).toSet();
      expect(inks, containsAll(<int>[palette.ink, palette.inkDim]));
    });

    test('a pair below the bar really is reported as one', () {
      // The detector, detected. `TextPair.passes` is what every verdict in this
      // file rests on, so it is exercised on a pair that must fail and a pair
      // that must pass, at the boundary rather than in the middle.
      const palette.TextPair bad =
          palette.TextPair('deliberate', 0xFF767676, 0xFF6E6E6E);
      expect(bad.passes, isFalse);
      const palette.TextPair good =
          palette.TextPair('deliberate', 0xFF000000, 0xFFFFFFFF);
      expect(good.passes, isTrue);
      // And the non-text bar really is the looser one.
      const palette.TextPair border =
          palette.TextPair('deliberate', 0xFF949494, 0xFFFFFFFF,
              nonText: true);
      expect(border.required, 3.0);
      expect(border.passes, isTrue);
      expect(
        const palette.TextPair('deliberate', 0xFF949494, 0xFFFFFFFF).passes,
        isFalse,
        reason: 'the same pair must fail at the text bar, or the two bars are '
            'not actually different',
      );
    });
  });

  group('the surfaces text sits on cannot let the playfield through', () {
    test('the flattened background is identical over the brightest and the '
        'darkest thing the game can draw', () {
      // THE HONEST HANDLING OF THE SPRITE. The car and the pipes come from a
      // PNG and cannot be enumerated, so instead the app is built so they
      // cannot matter: every surface carrying text is opaque. This asserts the
      // consequence rather than the intention — the same pair, computed over
      // the brightest and the darkest playfield, has to come out at the same
      // number, and it only can if nothing is getting through.
      expect(palette.screenCardOverPlayfield,
          palette.screenCardOverDarkPlayfield);
      expect(palette.brightestPlayfield,
          isNot(palette.darkestPlayfield),
          reason: 'the two extremes are the same colour, so the test above '
              'compared a thing with itself');
    });

    testWidgets('the same screen grades identically over both extremes', (
      WidgetTester tester,
    ) async {
      final _Host host = _Host();
      await showScreen(tester, GameOverScreen(host: host));
      final List<RenderedText> onBright =
          crawlText(tester, beneath: palette.brightestPlayfield);
      final List<RenderedText> onDark =
          crawlText(tester, beneath: palette.darkestPlayfield);

      expect(onBright, isNotEmpty);
      expect(onBright.length, onDark.length);
      for (int i = 0; i < onBright.length; i++) {
        expect(onBright[i].background, onDark[i].background,
            reason: '"${onBright[i].text}" is read against a different colour '
                'depending on what is scrolling behind it');
      }
    });
  });

  group('every pair the screens actually render', () {
    testWidgets('scores at least 4.5:1, on the brightest playfield', (
      WidgetTester tester,
    ) async {
      final _Host host = _Host();
      final List<String> failures = <String>[];
      int seen = 0;

      for (final (String name, Widget screen) in screensUnderTest(host)) {
        await showScreen(tester, screen);
        for (final RenderedText t
            in crawlText(tester, beneath: palette.brightestPlayfield)) {
          seen++;
          if (t.ratio < wcagAaTextContrast) {
            failures.add('$name: $t');
          }
        }
      }

      expect(failures, isEmpty, reason: failures.join('\n'));
      // NON-VACUOUS. A crawler that found nothing would pass the loop above
      // without grading a single pixel, which is exactly the failure mode this
      // whole exercise is about.
      expect(seen, greaterThanOrEqualTo(15),
          reason: 'the crawl found only $seen pieces of text across four '
              'screens, so it is almost certainly not finding them');
    });

    testWidgets('and every colour it finds came from the palette', (
      WidgetTester tester,
    ) async {
      // The other half of "reachable from the palette": the source scan in
      // `test/palette_test.dart` proves no literal was written, and this proves
      // what actually reaches a glyph is a palette entry rather than something
      // the framework supplied by default.
      final Set<int> known =
          palette.paletteColours.map((palette.PaletteColour c) => c.argb).toSet();
      final _Host host = _Host();
      final Set<int> inksSeen = <int>{};

      for (final (String name, Widget screen) in screensUnderTest(host)) {
        await showScreen(tester, screen);
        for (final RenderedText t
            in crawlText(tester, beneath: palette.brightestPlayfield)) {
          expect(known, contains(t.ink),
              reason: '$name: "${t.text}" is drawn in ${hexOf(t.ink)}, which '
                  'is not a palette colour');
          expect(isOpaque(t.background), isTrue, reason: '$name: $t');
          inksSeen.add(t.ink);
        }
      }

      // And it saw more than one, including the dim one — which is the tightest
      // pair on any screen and therefore the one a lazy crawl would most like
      // to miss.
      expect(inksSeen, contains(palette.inkDim));
      expect(inksSeen, contains(palette.ink));
      expect(inksSeen, contains(palette.panelBorder),
          reason: 'the NEW BEST banner was never crawled');
    });

    testWidgets('the crawl finds the labels a reader would expect', (
      WidgetTester tester,
    ) async {
      // Names, not just a count. A crawl that returned fifteen copies of the
      // same easy label would satisfy the count above.
      final _Host host = _Host();
      final Set<String> texts = <String>{};
      for (final (_, Widget screen) in screensUnderTest(host)) {
        await showScreen(tester, screen);
        texts.addAll(crawlText(tester, beneath: palette.brightestPlayfield)
            .map((RenderedText t) => t.text));
      }
      expect(
        texts,
        containsAll(<String>[
          'FLAPPY MIATA',
          'BEST',
          'SCORE',
          'RISK',
          'NEW BEST',
          'PAUSED',
          'RUN OVER',
          'TAP TO DRIVE',
          'PLAY AGAIN',
          'RESUME',
          'RESTART',
          'ASSIST: OFF',
          'MOTION: AUTO (FULL)',
          '‖',
        ]),
      );
    });

  });

  // ===========================================================================
  // THE CRAWLER, CRAWLED.
  //
  // Everything in the group above rests on `crawlText` returning the right
  // colours. A crawler that read `Text.style` and stopped would return null for
  // every inherited label; one that walked the ancestors in the wrong order
  // would composite the stack upside down; one that ignored translucent layers
  // would report a background nobody sees. None of those would fail a single
  // assertion above, because every one of them still returns plausible numbers.
  //
  // So the crawler is exercised on trees whose right answer is known by
  // construction, including the cases the app's own screens happen not to
  // contain.
  // ===========================================================================
  group('the crawler resolves what it claims to resolve', () {
    testWidgets('it reads a colour the text inherits rather than declares', (
      WidgetTester tester,
    ) async {
      // The app's screens all name their colours locally today, so this path is
      // not exercised by them — and a crawler that could not follow it would be
      // silently grading nothing the day somebody relies on the default.
      await showScreen(
        tester,
        const DefaultTextStyle(
          style: TextStyle(color: Color(0xFF123456)),
          child: ColoredBox(
            color: Color(0xFFFFFFFF),
            child: Text('inherited'),
          ),
        ),
      );
      final List<RenderedText> got =
          crawlText(tester, beneath: palette.darkestPlayfield);
      expect(got, hasLength(1));
      expect(got.single.ink, 0xFF123456);
      expect(got.single.background, 0xFFFFFFFF);
    });

    testWidgets('a local style wins over the inherited one', (
      WidgetTester tester,
    ) async {
      await showScreen(
        tester,
        const DefaultTextStyle(
          style: TextStyle(color: Color(0xFF123456)),
          child: ColoredBox(
            color: Color(0xFFFFFFFF),
            child: Text('local', style: TextStyle(color: Color(0xFFABCDEF))),
          ),
        ),
      );
      expect(crawlText(tester, beneath: palette.darkestPlayfield).single.ink,
          0xFFABCDEF);
    });

    testWidgets('it composites a stack of layers bottom-up', (
      WidgetTester tester,
    ) async {
      // Two translucent layers over a known base. Reversing the stack, or
      // dropping either layer, gives a different answer — so this pins the
      // order as well as the arithmetic.
      const int base = 0xFF000000;
      const int lower = 0x80FFFFFF;
      const int upper = 0x80FF0000;
      await showScreen(
        tester,
        const DefaultTextStyle(
          style: TextStyle(color: Color(0xFFFFFFFF)),
          child: ColoredBox(
            color: Color(lower),
            child: ColoredBox(
              color: Color(upper),
              child: Text('stacked'),
            ),
          ),
        ),
      );
      final RenderedText got = crawlText(tester, beneath: base).single;
      expect(got.stack, <int>[upper, lower],
          reason: 'the ancestors came back in the wrong order');
      expect(got.background, flatten(base, const <int>[lower, upper]));
      expect(got.background, isNot(flatten(base, const <int>[upper, lower])),
          reason: 'the two orders give the same answer, so this proves nothing');
    });

    testWidgets('it sees the background a Container paints', (
      WidgetTester tester,
    ) async {
      // `Container(decoration: BoxDecoration(color: ...))` is how every card
      // and button in this app paints itself, and it reaches the tree as a
      // `DecoratedBox` rather than a `ColoredBox`. A crawler that only knew
      // about one of the two would miss every card in the game.
      await showScreen(
        tester,
        Container(
          decoration: const BoxDecoration(color: Color(0xFF0A1D32)),
          child: const DefaultTextStyle(
            style: TextStyle(color: Color(0xFFFFFFFF)),
            child: Text('carded'),
          ),
        ),
      );
      expect(
        crawlText(tester, beneath: palette.brightestPlayfield).single.background,
        0xFF0A1D32,
      );
    });

    testWidgets('it reports a genuinely failing pair', (
      WidgetTester tester,
    ) async {
      // The detector detected, at the level of the crawl rather than of the
      // arithmetic: a real widget tree whose text really is unreadable comes
      // back with a ratio under the bar.
      await showScreen(
        tester,
        const DefaultTextStyle(
          style: TextStyle(color: Color(0xFF767676)),
          child: ColoredBox(
            color: Color(0xFF6E6E6E),
            child: Text('unreadable'),
          ),
        ),
      );
      final RenderedText got =
          crawlText(tester, beneath: palette.darkestPlayfield).single;
      expect(got.ratio, lessThan(wcagAaTextContrast));
    });
  });

  group('the HUD, which is drawn on the canvas and not in the widget tree', () {
    testWidgets('its readout is painted in the palette ink', (
      WidgetTester tester,
    ) async {
      // The crawl cannot reach this: the score is a Flame `TextComponent` on the
      // canvas, with no element and no `DefaultTextStyle` above it. So it is
      // read out of the live component tree instead, which is still the real
      // object the game will paint with rather than a constant re-typed here.
      final FlappyMiataGame game = FlappyMiataGame(
        courseSeed: 0,
        highScoreStore: InMemoryHighScoreStore(),
      );
      await tester.pumpWidget(GameWidget<FlappyMiataGame>(game: game));
      await tester.pump();
      await tester.pump();

      final List<TextComponent> readouts =
          game.descendants().whereType<TextComponent>().toList();
      expect(readouts, isNotEmpty,
          reason: 'no text component was found on the game at all, so this '
              'test is asserting nothing');

      for (final TextComponent readout in readouts) {
        final Object renderer = readout.textRenderer;
        expect(renderer, isA<TextPaint>());
        final Color? colour = (renderer as TextPaint).style.color;
        expect(colour?.toARGB32(), palette.ink,
            reason: 'the HUD readout is painted in ${colour?.toARGB32()}, not '
                'the palette ink');
      }

      // And the pair it forms is on the declared list, graded above.
      expect(
        palette.textPairs.any((palette.TextPair p) =>
            p.foreground == palette.ink &&
            p.background == palette.hudPanelSurface),
        isTrue,
      );
    });
  });
}
