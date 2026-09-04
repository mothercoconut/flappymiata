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
import 'package:flappymiata/ui/motion.dart';
import 'package:flappymiata/ui/palette.dart' as palette;

// -----------------------------------------------------------------------------
// The palette.
//
// EVERY COLOUR BELOW IS A REFERENCE, NOT A LITERAL. The values live in
// `lib/ui/palette.dart`, which is the only file in `lib/` allowed to contain a
// hex colour — `test/palette_test.dart` scans the source and fails the suite if
// one appears anywhere else. That is what makes "every pair the UI renders is
// reachable from the palette" a checked fact rather than a habit: a colour that
// is not in the palette is a colour nothing grades for contrast, and now it is
// also a colour that will not compile past the tests.
//
// These stay declared here, as `Color`s, because that is what the widget tree
// wants and because `lib/ui/palette.dart` is deliberately pure Dart with no
// `dart:ui` in it, so that `tool/palette_report.dart` can run it.
// -----------------------------------------------------------------------------

/// The card's fill. Fully opaque: see `palette.cardSurface` for why the 5% it
/// used to let through was a real problem and not a nicety.
const Color screenCardBacking = Color(palette.cardSurface);

/// The teal that outlines every panel in this game.
const Color screenBorder = Color(palette.panelBorder);

/// Text on a card.
const Color screenInk = Color(palette.ink);

/// Secondary text — labels, hints — dimmer so the numbers read first.
const Color screenInkDim = Color(palette.inkDim);

/// A wash over the whole playfield while a screen is up.
///
/// Translucent rather than opaque on purpose: the pipes and the car stay
/// visible behind it, so a paused game still looks like the game, and a game
/// over still shows the wreck it is reporting. No text is ever drawn directly
/// on it — every label sits on [screenCardBacking] — which is what keeps its
/// translucency out of the contrast arithmetic.
const Color screenScrim = Color(palette.scrim);

/// The fill of a button.
const Color screenButtonFill = Color(palette.buttonFill);

/// The fill of a button that is not the primary one: nothing, so the card shows
/// through.
const Color screenButtonPlainFill = Color(palette.buttonPlainFill);

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

  /// Points scored in the current run: obstacles passed, and nothing else. This
  /// is the number a run code is verified against.
  int get score;

  /// Points earned in the current run for how CLOSE the passes were.
  ///
  /// Shown beside [score] rather than folded into it, for the reason
  /// `GameModel.score` gives: every stored record and every run code in
  /// existence claims the obstacle count, and quietly redefining what "score"
  /// means would invalidate all of them at once.
  int get riskScore;

  /// The best score that has ever been recorded on this device, or 0 if there
  /// is none yet.
  int get bestScore;

  /// False until a best score has been loaded or set, so that "best: 0" and
  /// "no best yet" can be told apart on screen.
  bool get hasBestScore;

  /// Whether the run that just ended IMPROVED on the best score known when it
  /// started.
  ///
  /// ==========================================================================
  /// WHY THIS IS A FLAG ON THE HOST AND NOT A COMPARISON ON THE SCREEN
  /// ==========================================================================
  ///
  /// It was a comparison, `score >= bestScore`, on the argument that a run only
  /// ever ties or beats the record at the moment it ends, so equality had to
  /// mean "this run set it". That argument is false, and it shipped a bug: a
  /// first run scoring NOTHING records a best of 0, and 0 >= 0 congratulated
  /// the player for it. A run that merely TIES an older record does the same.
  ///
  /// The reason no comparison can work is worth stating, because the next
  /// person to look at this will want to try a different one. By the time this
  /// screen is built the best has ALREADY been written, so `score` and
  /// `bestScore` are equal in two completely different situations — the run
  /// that just set the record, and a run that tied one set last week. The
  /// information that separates them is the PREVIOUS best, and it no longer
  /// exists anywhere on this interface. It is not a comparison the screen is
  /// getting wrong; it is a fact the screen has not been told.
  ///
  /// So the game says it. The flag is set in exactly one place — the same
  /// branch that writes the new best — which is what keeps it in step with the
  /// number it describes.
  bool get isNewBest;

  /// Whether the world is currently stopped.
  bool get paused;

  /// Whether the flap-window highlight is being drawn.
  ///
  /// A DISPLAY SETTING AND NOTHING ELSE. It reaches no rule: the model does not
  /// know it exists, the recorder does not write it down, and a run played with
  /// it on and the same run played with it off are the same run. See
  /// `lib/ui/assist.dart` for why that has to be true and how it is asserted.
  bool get assistEnabled;

  /// Turns the flap-window highlight on or off. Off is the default.
  void toggleAssist();

  /// What the player has asked for about decorative motion.
  ///
  /// Defaults to [MotionSetting.system], which follows the platform's own
  /// "reduce motion" accessibility switch. See `lib/ui/motion.dart`.
  MotionSetting get motionSetting;

  /// What that platform switch currently says.
  ///
  /// Exposed beside [motionSetting] rather than folded into it because the
  /// control has to be able to say which of the two decided the answer: "AUTO"
  /// on its own does not tell a player whether the background is about to
  /// move.
  bool get systemDisablesAnimations;

  /// Steps the motion setting on: system, then reduced, then full.
  ///
  /// A DISPLAY SETTING AND NOTHING ELSE, exactly like [toggleAssist]. It stops
  /// the parallax and it changes no rule: the model does not know it exists and
  /// a run played either way is the same run. `test/reduced_motion_test.dart`
  /// asserts that frame for frame, because a reduced-motion mode that quietly
  /// made the game easier would be a different feature wearing this one's name.
  void cycleMotion();

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
          color: primary ? screenButtonFill : screenButtonPlainFill,
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
        const SizedBox(height: 12),
        AssistToggle(host: host),
        const SizedBox(height: 12),
        MotionToggle(host: host),
      ],
    );
  }
}

/// The assist switch, offered on the two screens where the world is stopped.
///
/// NOT offered during play. The label has to be read to be useful and reading
/// it costs the run; and a control on the playfield is a control a flap can hit
/// by accident. Both screens that show it are screens the player is already
/// stopped on.
///
/// The label states the CURRENT state rather than the action, so a glance
/// answers "is it on?" — which is the question somebody who has just been shown
/// an unexpected line across the screen is asking.
class AssistToggle extends StatelessWidget {
  /// The game.
  final GameScreenHost host;

  const AssistToggle({super.key, required this.host});

  @override
  Widget build(BuildContext context) {
    return GameButton(
      label: host.assistEnabled ? 'ASSIST: ON' : 'ASSIST: OFF',
      onPressed: host.toggleAssist,
    );
  }
}

/// The reduced-motion switch, offered beside the assist toggle and for the same
/// reason: both are display settings, both need their label read, and reading a
/// label costs a run if it is done during one.
///
/// The label states the CURRENT state rather than the action. On
/// [MotionSetting.system] it also names what the platform resolved to, since
/// the question somebody presses this to answer is "will the background move",
/// and only the resolved state answers it.
class MotionToggle extends StatelessWidget {
  /// The game.
  final GameScreenHost host;

  const MotionToggle({super.key, required this.host});

  @override
  Widget build(BuildContext context) {
    return GameButton(
      label: motionSettingLabel(
        setting: host.motionSetting,
        systemDisablesAnimations: host.systemDisablesAnimations,
      ),
      onPressed: host.cycleMotion,
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
        const SizedBox(height: 12),
        ScoreReadout(label: 'RISK', value: '${host.riskScore}'),
        const SizedBox(height: 20),
        GameButton(label: 'RESUME', onPressed: host.resumeRun, primary: true),
        const SizedBox(height: 12),
        GameButton(label: 'RESTART', onPressed: host.restartRun),
        const SizedBox(height: 12),
        AssistToggle(host: host),
        const SizedBox(height: 12),
        MotionToggle(host: host),
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
    // Asked, not deduced. See [GameScreenHost.isNewBest] for why the deduction
    // this used to make cannot be made from anything on screen.
    final bool isBest = host.isNewBest;

    return GameScreenScaffold(
      onTapAnywhere: host.restartRun,
      children: <Widget>[
        const ScreenTitle('RUN OVER'),
        const SizedBox(height: 16),
        ScoreReadout(label: 'SCORE', value: '${host.score}'),
        const SizedBox(height: 12),
        // Beside the score, never added to it. The two numbers answer different
        // questions — how far, and how close — and a single total would hide
        // both. It is also the number no record is verified against, so keeping
        // them apart on screen keeps them apart in the player's head.
        ScoreReadout(label: 'RISK', value: '${host.riskScore}'),
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
