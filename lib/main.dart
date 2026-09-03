/// The real entry point: the rules in `lib/game/`, drawn and made playable.
///
/// WHAT THIS FILE IS, AND WHAT IT IS NOT
///
/// It is the wiring between two halves that deliberately know nothing about
/// each other. `lib/game/` owns the rules and cannot draw — it has no Flame and
/// no Flutter import at all. This file can draw and owns no rules: every number
/// that decides how the game *behaves* lives in `GameModel`, and if one starts
/// creeping in here it belongs over there instead.
///
/// It is also deliberately PLAIN. Flat rectangles, one colour each, no sprites,
/// no menus, no animation beyond the game itself. Presentation is `lib/ui/`,
/// that directory is owned by a teammate, and this file leaves the design space
/// empty on purpose. The point of this file is that the game can be run and new
/// components can be tested against something that works — not that it looks
/// finished.
library;

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/widgets.dart';

import 'package:flappymiata/game/game_model.dart';

// -----------------------------------------------------------------------------
// DRAW ORDER.
//
// Flame paints sibling components in ascending `priority`: the lowest number is
// laid down first and everything after it lands on top. So the layer that has
// to stay readable needs the HIGHER number, and these two constants are the
// only place that decision is recorded.
//
// WHY THIS IS SPELLED OUT RATHER THAN LEFT TO CHANCE: the obstacles scroll
// across the FULL width of the screen, so the score is not tucked away in a
// safe corner — every pipe passes over it, a few seconds after the run starts.
// The dev harness hit exactly this: it painted the world onto the canvas AFTER
// the component tree had already drawn, which puts the pipes over the text
// unconditionally and no component priority can undo it. An ordering that
// depends on which line of code ran last is invisible in review; an ordering
// that is a number attached to a layer is not.
// -----------------------------------------------------------------------------

/// Pipes and car. Lowest, so they are painted underneath everything else.
const int _worldPriority = 0;

/// The score panel. Set far above [_worldPriority] rather than one step above
/// it, so a layer added later — `lib/ui/` will want some — has somewhere to sit
/// in between without anyone renumbering these.
const int _hudPriority = 100;

void main() {
  runApp(const FlappyMiataApp());
}

/// THIS WIDGET IS DELIBERATELY THIN.
///
/// `lib/main.dart` is the one file both people in this repo have to touch, so
/// every line here is a line that can collide on merge. Its job is wiring only:
/// start the app, hand Flutter a game. Input and drawing live on the game
/// below; gameplay lives in `lib/game/`; screens and menus belong in `lib/ui/`,
/// where one person can own a file outright.
class FlappyMiataApp extends StatelessWidget {
  const FlappyMiataApp({super.key});

  @override
  Widget build(BuildContext context) {
    // `.controlled` lets the widget's own State create and keep the game
    // instance. Building `GameWidget(game: FlappyMiataGame())` directly would
    // construct a fresh game on every rebuild and throw away the run in
    // progress.
    return const GameWidget<FlappyMiataGame>.controlled(
      gameFactory: FlappyMiataGame.new,
    );
  }
}

/// The renderer half. Everything in this class may import Flame and Flutter;
/// nothing in it is allowed to decide how the game behaves.
///
/// It owns one [GameModel] snapshot and the two layers that read it —
/// [_WorldLayer] underneath and [_ScorePanel] on top. Neither layer holds state
/// of its own: each draws whatever snapshot this class is holding at the moment
/// it is asked to.
///
/// `TapCallbacks` is mixed in at the GAME level rather than onto a component,
/// because a tap anywhere on screen should count. A `FlameGame` is itself a
/// Component and reports every point inside the canvas as its own, so the whole
/// surface becomes the tap target with no invisible button to size or place.
class FlappyMiataGame extends FlameGame with TapCallbacks {
  /// The single source of truth about the run.
  ///
  /// REPLACED EVERY FRAME, NEVER MUTATED. `GameModel` is immutable and `tick`
  /// is a pure function from (snapshot, dt) to the next snapshot, so "advance
  /// the game" means "point this field at the object that came back". Two
  /// things fall out of that, and both are why the model was written this way:
  ///
  ///  - Nothing can change the game behind this renderer's back. The snapshot
  ///    being drawn stays true until the line in [update] deliberately replaces
  ///    it, so a half-updated frame is not expressible.
  ///  - The rules stay testable without a screen. `flutter test` runs thousands
  ///    of ticks in milliseconds precisely because no renderer is involved in
  ///    producing them — see `lib/game/README.md`.
  ///
  /// The consequence to remember when editing this file: the RETURN VALUE of
  /// `tick`, `flap` and `reset` is the game. Calling one and dropping the
  /// result does nothing at all.
  GameModel _model = const GameModel.ready();

  /// Read-only view of the current snapshot, for anything that draws.
  ///
  /// Public so that `lib/ui/` can render from it without this file handing out
  /// a way to change it. Assignment stays private: the only legal ways to move
  /// the run on are the model's own `tick`, `flap` and `reset`.
  GameModel get model => _model;

  late final _ScorePanel _panel;

  /// Flat fill, painted before any component draws. No gradient, on purpose.
  @override
  Color backgroundColor() => const Color(0xFF0B2545);

  @override
  Future<void> onLoad() async {
    await super.onLoad();

    _panel = _ScorePanel();
    // Added in this order for readability only. The priorities the two classes
    // carry are what actually decide who covers whom, so swapping these two
    // entries changes nothing on screen — which is the point of using
    // priorities rather than insertion order.
    await addAll(<Component>[_WorldLayer(), _panel]);

    // So the "tap to start" hint is on screen for the very first frame, rather
    // than appearing only once `update` has run once.
    _panel.text = _hudText;
  }

  /// A tap means "flap" during a run and "start again" once the run is over.
  ///
  /// The model refuses flaps while dead all by itself, so this branch is about
  /// intent rather than safety: `reset()` is the deliberate way back, and
  /// keeping it off `flap()` is what lets the player see the final frame
  /// instead of having a stray tap wipe it.
  @override
  void onTapDown(TapDownEvent event) {
    _model = _model.state == RunState.dead ? _model.reset() : _model.flap();
    _panel.text = _hudText;
  }

  @override
  void update(double dt) {
    super.update(dt);

    // The ONE place real time enters the model. Flame measures how long the
    // frame took; the model just receives a number of seconds and has no clock
    // of its own. That indirection is why an identical run can be replayed
    // exactly in a test where no real time passes at all.
    _model = _model.tick(dt);

    _panel.text = _hudText;
  }

  /// The score, plus a hint in the two states where the game is waiting on the
  /// player. No hint while playing: it would be one more thing sitting over the
  /// pipes with nothing left to say.
  String get _hudText {
    final String score = 'score: ${_model.score}';
    switch (_model.state) {
      case RunState.ready:
        return '$score\ntap to start';
      case RunState.playing:
        return score;
      case RunState.dead:
        return '$score\ntap to restart';
    }
  }
}

/// Everything that scrolls: both pipes of every obstacle, and the car. Sits at
/// [_worldPriority], i.e. underneath the score.
///
/// ONE component for the whole world rather than one component per obstacle,
/// because `tick` rebuilds the obstacle list from scratch every frame. The
/// model already owns those objects; mirroring them into a component tree would
/// mean adding and removing components sixty times a second in order to display
/// data that is already sitting in a field.
class _WorldLayer extends Component with HasGameReference<FlappyMiataGame> {
  _WorldLayer() : super(priority: _worldPriority);

  /// One flat colour for every pipe, scored or not. A second colour here would
  /// be a presentation decision, and presentation is `lib/ui/`'s to make.
  static final Paint _pipePaint = Paint()..color = const Color(0xFF3DDC84);

  /// The car. A rectangle, not a sprite: what is drawn is exactly the box that
  /// collision is tested against, so a near miss that looks like a hit is one.
  static final Paint _carPaint = Paint()..color = const Color(0xFFE23D28);

  @override
  void render(Canvas canvas) {
    for (final Obstacle obstacle in game.model.obstacles) {
      // Drawing the model's own `topBox` and `bottomBox` rather than working
      // the rectangles out again here. Recomputed geometry can disagree with
      // the geometry collision uses and still look convincing on screen; taking
      // the boxes straight from the model makes that disagreement impossible.
      canvas.drawRect(_toPixels(obstacle.topBox), _pipePaint);
      canvas.drawRect(_toPixels(obstacle.bottomBox), _pipePaint);
    }

    canvas.drawRect(_toPixels(game.model.carBox), _carPaint);
  }

  /// THE ONE CONVERSION THE MODEL REFUSES TO DO: a normalised box — 0..1 on
  /// both axes — becomes pixels by multiplying x by the screen width and y by
  /// the screen height.
  ///
  /// WHY IT HAPPENS HERE, AT RENDER TIME, RATHER THAN ONCE AT STARTUP: the
  /// screen size is not a constant. It changes on rotation, on a window resize,
  /// on a foldable opening. Converting every frame means the game is always
  /// drawn against the size it actually has right now, and the model never has
  /// to be told that anything moved — the numbers in it are fractions of the
  /// playfield, so they were already correct at both sizes. That is also what
  /// makes a phone and a tablet play an identical game.
  ///
  /// The two axes are scaled by different numbers, so a shape that is square in
  /// model coordinates comes out stretched on a tall screen. Accepted: the car
  /// and the pipes are rectangles either way, and nothing in the rules is
  /// affected, because collision is tested in model coordinates and never in
  /// pixels.
  Rect _toPixels(Box box) {
    final Vector2 screen = game.size;
    return Rect.fromLTRB(
      box.left * screen.x,
      box.top * screen.y,
      box.right * screen.x,
      box.bottom * screen.y,
    );
  }
}

/// The score and hint text on an opaque backing panel, at [_hudPriority] —
/// above everything the world layer draws.
///
/// WHY THE BACKING IS NOT DECORATION: priority fixes the ordering, and ordering
/// alone does not fix legibility. Pale glyphs sitting directly on the bright
/// green of a pipe are a contrast problem rather than a depth one, and they
/// stay hard to read even once they are unmistakably in front. An opaque
/// rectangle underneath makes the colour behind the text a known quantity no
/// matter what is passing beneath it.
class _ScorePanel extends PositionComponent {
  _ScorePanel()
    : super(
        // Pushed down from the top edge rather than starting at y = 0: on a
        // phone the first line would sit directly under the status bar clock
        // and the two overlap into a smear. 48 logical pixels clears it.
        position: Vector2(16, 48),
        priority: _hudPriority,
      );

  /// Breathing room between the glyphs and the edge of the panel. Without it
  /// the backing stops exactly at the ink and reads as a highlighter stripe
  /// rather than as a panel.
  static const double _padding = 8.0;

  /// THE ALPHA BYTE IS `FF` AND HAS TO STAY `FF`. The entire job of this
  /// rectangle is that pipe colour cannot show through it. Anything below full
  /// alpha quietly reintroduces the unreadable-score problem, and it would only
  /// show up in the handful of frames a pipe spends behind the text.
  static final Paint _backing = Paint()..color = const Color(0xFF06172E);

  /// Added as a CHILD rather than drawn inside [render], because Flame draws a
  /// component's children after the component itself. That is the same
  /// low-paints-first rule as the two layer priorities above, and it is what
  /// puts the glyphs on top of their own backing instead of under it.
  final TextComponent _readout = TextComponent(
    position: Vector2(_padding, _padding),
    textRenderer: TextPaint(
      style: const TextStyle(
        color: Color(0xFFFFFFFF),
        fontSize: 20.0,
        height: 1.4,
      ),
    ),
  );

  /// Sets the text, and resizes the panel to match it.
  ///
  /// The panel is measured FROM the text instead of being given a fixed size,
  /// because the content changes shape: `score: 9` and `score: 148` are not the
  /// same number of pixels wide, and the hint line comes and goes with the run
  /// state. A guessed constant is either padded out with dead space or one
  /// character too narrow — and the too-narrow version puts the end of a line
  /// back on top of a pipe, which is the exact problem the backing exists to
  /// prevent.
  ///
  /// The early return is because this is called on every frame and the text
  /// changes only when the score or the state does. Re-laying-out a paragraph
  /// sixty times a second to arrive at the same pixels is work nobody sees.
  set text(String value) {
    if (_readout.text == value) return;
    _readout.text = value;
    size.setValues(
      _readout.size.x + _padding * 2,
      _readout.size.y + _padding * 2,
    );
  }

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    await add(_readout);
  }

  @override
  void render(Canvas canvas) {
    // Local coordinates: PositionComponent has already applied this panel's own
    // translation, so (0, 0) here is the panel's top-left corner. Size stays
    // zero until the first `text` set, and a zero-sized rect draws nothing —
    // which is the right thing to show before there is anything to say.
    canvas.drawRect(Rect.fromLTWH(0, 0, size.x, size.y), _backing);
  }
}
