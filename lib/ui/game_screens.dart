/// The screens: start, paused, and game over.
///
/// ============================================================================
/// WHY THESE ARE FLUTTER WIDGETS AND NOT MORE FLAME COMPONENTS
/// ============================================================================
///
/// `lib/main.dart` already draws a card and some text onto the canvas, which
/// works and is why the game has been playable without this file. It does not
/// scale: a menu is buttons, hit areas, text that wraps, and a layout that has
/// to survive a rotation — all of which Flutter already does and all of which
/// would be hand-rolled arithmetic inside a `render` method here.
///
/// Flame's overlays are the seam for exactly this. A named widget is stacked
/// over the game surface, the game says which names are active, and the widget
/// tree does the rest. The game loop is untouched.
///
/// ============================================================================
/// WHY THESE WIDGETS DO NOT KNOW WHAT A `FlappyMiataGame` IS
/// ============================================================================
///
/// They talk to a [GameScreenHost] instead. The dependency then points ONE way —
/// `lib/main.dart` knows about `lib/ui/`, and `lib/ui/` does not know about
/// `lib/main.dart` — which is the same one-way rule `lib/game/` already lives
/// under, for the same reason: it keeps a thing testable without booting the
/// thing above it. `test/game_screens_test.dart` drives every screen in this
/// file with a plain fake and no game loop at all.
///
/// ============================================================================
/// THE ART IS MAIN.DART'S ART
/// ============================================================================
///
/// The colours, the 3px teal border, the 16px corner radius and the border
/// dropped six pixels below the card are lifted from the score panel that is
/// already on screen. This file is not a redesign; it is the same panel, bigger,
/// with buttons on it.
library;

import 'package:flame/game.dart';
import 'package:flutter/widgets.dart';

import 'package:flappymiata/game/game_model.dart';

// -----------------------------------------------------------------------------
// The palette, taken from lib/main.dart so the screens sit on the game rather
// than on top of it.
// -----------------------------------------------------------------------------

/// The card's fill. Nearly opaque, so nothing scrolling underneath shows
/// through the text.
const Color screenCardBacking = Color(0xF20A1D32);

/// The teal that outlines every panel in this game.
const Color screenBorder = Color(0xFF8BD3C7);

/// Text on a card.
const Color screenInk = Color(0xFFFFFFFF);

/// Secondary text — labels, hints — dimmer so the numbers read first.
const Color screenInkDim = Color(0xFFA8C4D8);

/// A wash over the whole playfield while a screen is up.
///
/// Translucent rather than opaque on purpose: the pipes and the car stay
/// visible behind it, so a paused game still looks like the game, and a game
/// over still shows the wreck it is reporting.
const Color screenScrim = Color(0xB3061224);

/// The fill of a button.
const Color screenButtonFill = Color(0xFF17385C);

// -----------------------------------------------------------------------------
// Overlay names.
// -----------------------------------------------------------------------------

/// Shown before the first tap of a run.
const String startOverlay = 'start';

/// Shown while the run is paused.
const String pausedOverlay = 'paused';

/// Shown once the car has crashed.
const String gameOverOverlay = 'gameOver';

/// The small pause control, shown only while a run is live.
const String pauseButtonOverlay = 'pauseButton';

/// Every overlay this file registers.
///
/// The game diffs the wanted set against this list, so a name added here and
/// nowhere else is a name that will never be shown — and, more usefully, a name
/// REMOVED from a screen but left in this list still gets cleaned up rather than
/// being stranded on screen for the rest of the session.
const List<String> gameScreenOverlays = <String>[
  startOverlay,
  pausedOverlay,
  gameOverOverlay,
  pauseButtonOverlay,
];

/// Which overlays belong on screen for a given run state.
///
/// A PURE FUNCTION, kept separate from the game, because "which screen is up" is
/// the one piece of screen logic that can be wrong in a way nobody sees until it
/// is on a device: two screens at once, or none. As a function of two arguments
/// it is checked exhaustively in a test that boots nothing.
///
/// [paused] wins over everything. Pausing is a state the model does not have —
/// `RunState` is deliberately three values and none of them is "paused", because
/// stopping the world is a rendering decision — so it is tracked beside the
/// model and read first.
Set<String> overlaysFor({required RunState state, required bool paused}) {
  if (paused) return const <String>{pausedOverlay};
  switch (state) {
    case RunState.ready:
      return const <String>{startOverlay};
    case RunState.playing:
      return const <String>{pauseButtonOverlay};
    case RunState.dead:
      return const <String>{gameOverOverlay};
  }
}

// -----------------------------------------------------------------------------
// What a screen needs from the game.
// -----------------------------------------------------------------------------

/// The game, as far as these screens are concerned.
///
/// Deliberately tiny. Every method here is something a button does and every
/// getter is something a label shows; there is no way through this interface to
/// reach the model, the obstacles or the replay, so a screen cannot start
/// deciding how the game behaves.
abstract class GameScreenHost {
  /// Fires when something a screen DISPLAYS has changed without the screen
  /// itself changing.
  ///
  /// WHY THIS IS NEEDED AT ALL, because it is not obvious: a Flame overlay is
  /// rebuilt when the set of active overlays changes, and not otherwise. That
  /// covers almost everything here — a different screen means a different set —
  /// but not the one case where the SAME screen has new content. The best score
  /// arrives from storage asynchronously, some frames after the start screen is
  /// already up, and nothing about the overlay set changes when it does. Without
  /// this the record would simply not appear until the player did something
  /// else.
  ///
  /// Deliberately NOT bumped every frame. A rebuild per frame would make the
  /// widget tree do work the canvas is already doing better.
  Listenable get revision;

  /// Points scored in the current run.
  int get score;

  /// The best score that has ever been recorded on this device, or 0 if there
  /// is none yet.
  int get bestScore;

  /// False until a best score has been loaded or set, so that "best: 0" and
  /// "no best yet" can be told apart on screen.
  bool get hasBestScore;

  /// Whether the world is currently stopped.
  bool get paused;

  /// Leaves the start line: the first tap of a run.
  void startRun();

  /// Stops the world. Nothing advances until [resumeRun].
  void pauseRun();

  /// Starts the world again, from exactly where it stopped.
  void resumeRun();

  /// Throws the current run away and returns to the start line.
  void restartRun();
}

/// Registers every screen in this file on [game], reading its state from [host].
///
/// Called once, from the game's own `onLoad`, rather than being handed to the
/// `GameWidget` at the top of the app. Two reasons, and the second is the real
/// one:
///
///   1. `lib/main.dart` stays a wiring file — one line, not a map of builders.
///   2. The overlays then belong to the GAME rather than to one particular
///      widget that wraps it. A test that builds its own `GameWidget` around a
///      `FlappyMiataGame` gets the screens too, and Flame asserts when an
///      overlay is activated with no builder registered — so a game that could
///      show a screen in the app and not in a test would be a game whose tests
///      crash rather than one whose tests quietly check less.
///
/// Every registration is wrapped in a [ListenableBuilder] on
/// [GameScreenHost.revision]. That wrapper is here rather than inside each
/// screen so the screens stay plain widgets that read a host and build — which
/// is what lets a test put any of them on screen with a fake and no listenable
/// at all to arrange.
void registerGameScreens(Game game, GameScreenHost host) {
  void entry(String name, WidgetBuilder build) {
    game.overlays.addEntry(
      name,
      (BuildContext context, Game _) => ListenableBuilder(
        listenable: host.revision,
        builder: (BuildContext context, Widget? _) => build(context),
      ),
    );
  }

  entry(startOverlay, (BuildContext _) => StartScreen(host: host));
  entry(pausedOverlay, (BuildContext _) => PausedScreen(host: host));
  entry(gameOverOverlay, (BuildContext _) => GameOverScreen(host: host));
  entry(pauseButtonOverlay, (BuildContext _) => PauseButton(host: host));
}

// -----------------------------------------------------------------------------
// The shared furniture.
// -----------------------------------------------------------------------------

/// A card in the game's house style: teal outline, dark fill, and the outline
/// repeated six pixels lower so the card sits ON the playfield rather than
/// floating over it.
///
/// The offset border is drawn as a `boxShadow` with zero blur, which is the
/// widget-tree spelling of the two `drawRRect` calls `lib/main.dart` already
/// makes for its score panel.
class GameCard extends StatelessWidget {
  /// Stacked top to bottom, centred.
  final List<Widget> children;

  const GameCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 340),
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 26),
      decoration: BoxDecoration(
        color: screenCardBacking,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: screenBorder, width: 3),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: screenBorder, offset: Offset(0, 6)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// A button.
///
/// `GestureDetector` with `HitTestBehavior.opaque` rather than anything from
/// Material: opaque is what makes the whole rectangle a target including the
/// padding, and it is what stops a tap that misses the glyphs falling through to
/// the game and being read as a flap.
class GameButton extends StatelessWidget {
  /// The label. Upper case at the call site, not here, so the string in the
  /// source reads as what appears on screen.
  final String label;

  /// What the button does.
  final VoidCallback onPressed;

  /// The primary button on a screen is filled; the others are outlined.
  final bool primary;

  const GameButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
        decoration: BoxDecoration(
          color: primary ? screenButtonFill : const Color(0x00000000),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: screenBorder, width: 2),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: screenInk,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }
}

/// A full-screen scrim with a card centred on it.
///
/// [onTapAnywhere] is what makes the start and game-over screens behave the way
/// the game always has — a tap anywhere gets on with it. It is deliberately NOT
/// given to the paused screen: resuming on a stray touch is how a player loses a
/// run they had deliberately stopped.
class GameScreenScaffold extends StatelessWidget {
  /// The card's contents.
  final List<Widget> children;

  /// Called for a tap anywhere outside the card's own controls, or null to
  /// swallow those taps.
  final VoidCallback? onTapAnywhere;

  const GameScreenScaffold({
    super.key,
    required this.children,
    this.onTapAnywhere,
  });

  @override
  Widget build(BuildContext context) {
    // An explicit DefaultTextStyle rather than relying on an ancestor: this
    // widget is stacked straight onto a Flame surface, where there is no
    // MaterialApp and therefore no default text style with a colour in it.
    return DefaultTextStyle(
      style: const TextStyle(
        color: screenInk,
        fontSize: 16,
        decoration: TextDecoration.none,
      ),
      child: GestureDetector(
        // Opaque, so this layer always consumes the tap. Without it a tap on
        // the scrim would fall through to the game underneath and be read as a
        // flap — which on the game-over screen would restart the run by
        // accident.
        behavior: HitTestBehavior.opaque,
        onTap: onTapAnywhere,
        child: ColoredBox(
          color: screenScrim,
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: GameCard(children: children),
            ),
          ),
        ),
      ),
    );
  }
}

/// A big number with a small label above it.
class ScoreReadout extends StatelessWidget {
  /// What the number is.
  final String label;

  /// The number.
  final String value;

  const ScoreReadout({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(
            color: screenInkDim,
            fontSize: 13,
            letterSpacing: 2.0,
            decoration: TextDecoration.none,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: screenInk,
            fontSize: 40,
            fontWeight: FontWeight.w800,
            decoration: TextDecoration.none,
          ),
        ),
      ],
    );
  }
}

/// A screen heading.
class ScreenTitle extends StatelessWidget {
  /// The words.
  final String text;

  const ScreenTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(
        color: screenInk,
        fontSize: 26,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.5,
        decoration: TextDecoration.none,
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// The three screens.
// -----------------------------------------------------------------------------

/// Before the first tap.
class StartScreen extends StatelessWidget {
  /// The game.
  final GameScreenHost host;

  const StartScreen({super.key, required this.host});

  @override
  Widget build(BuildContext context) {
    return GameScreenScaffold(
      onTapAnywhere: host.startRun,
      children: <Widget>[
        const ScreenTitle('FLAPPY MIATA'),
        const SizedBox(height: 16),
        if (host.hasBestScore) ...<Widget>[
          ScoreReadout(label: 'BEST', value: '${host.bestScore}'),
          const SizedBox(height: 16),
        ],
        const Text(
          'Tap to lift. Let go to drop.\nThe course gets harder as you go.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: screenInkDim,
            fontSize: 15,
            height: 1.4,
            decoration: TextDecoration.none,
          ),
        ),
        const SizedBox(height: 20),
        GameButton(label: 'TAP TO DRIVE', onPressed: host.startRun, primary: true),
      ],
    );
  }
}

/// While the world is stopped.
///
/// NO `onTapAnywhere`. See [GameScreenScaffold]: the two buttons are the only
/// way off this screen, because a stray touch that resumed the game would undo
/// the reason the player paused it.
class PausedScreen extends StatelessWidget {
  /// The game.
  final GameScreenHost host;

  const PausedScreen({super.key, required this.host});

  @override
  Widget build(BuildContext context) {
    return GameScreenScaffold(
      children: <Widget>[
        const ScreenTitle('PAUSED'),
        const SizedBox(height: 16),
        ScoreReadout(label: 'SCORE', value: '${host.score}'),
        const SizedBox(height: 20),
        GameButton(label: 'RESUME', onPressed: host.resumeRun, primary: true),
        const SizedBox(height: 12),
        GameButton(label: 'RESTART', onPressed: host.restartRun),
      ],
    );
  }
}

/// After the crash.
class GameOverScreen extends StatelessWidget {
  /// The game.
  final GameScreenHost host;

  const GameOverScreen({super.key, required this.host});

  @override
  Widget build(BuildContext context) {
    // A run only ever ties or beats the stored best at the moment it ends, and
    // the game has already written it down by the time this is built — so
    // "equal to the best" IS "this run set it". Written as a comparison rather
    // than as a flag on the host, because a flag would be a second thing to keep
    // in step with the score it describes.
    final bool isBest = host.hasBestScore && host.score >= host.bestScore;

    return GameScreenScaffold(
      onTapAnywhere: host.restartRun,
      children: <Widget>[
        const ScreenTitle('RUN OVER'),
        const SizedBox(height: 16),
        ScoreReadout(label: 'SCORE', value: '${host.score}'),
        const SizedBox(height: 12),
        if (host.hasBestScore)
          ScoreReadout(label: 'BEST', value: '${host.bestScore}'),
        if (isBest) ...<Widget>[
          const SizedBox(height: 8),
          const Text(
            'NEW BEST',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: screenBorder,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 2.0,
              decoration: TextDecoration.none,
            ),
          ),
        ],
        const SizedBox(height: 20),
        GameButton(
          label: 'PLAY AGAIN',
          onPressed: host.restartRun,
          primary: true,
        ),
      ],
    );
  }
}

/// The pause control, shown only while a run is live.
///
/// Aligned into the top-right corner and nothing more. `Align` occupies the
/// stack but has no paint and no hit area of its own, so every tap that is not
/// on the button itself falls straight through to the game and is read as a
/// flap — which is what a tap on the playfield has always meant and has to go on
/// meaning.
class PauseButton extends StatelessWidget {
  /// The game.
  final GameScreenHost host;

  const PauseButton({super.key, required this.host});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topRight,
      child: Padding(
        // Clear of the status bar, matching the score panel's own 48px drop on
        // the other side of the screen.
        padding: const EdgeInsets.only(top: 48, right: 16),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: host.pauseRun,
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: screenCardBacking,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: screenBorder, width: 2),
            ),
            child: const Center(
              // Two bars, drawn as a glyph rather than as an icon font: the app
              // does not otherwise pull in Material's icons, and this is the
              // only symbol it needs.
              child: Text(
                '‖',
                style: TextStyle(
                  color: screenInk,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
