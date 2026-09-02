/// DISPOSABLE PHYSICS HARNESS — NOT THE GAME'S UI.
///
/// Run it with its own entry point, so `lib/main.dart` never has to change:
///
///     flutter run -t lib/dev/harness.dart
///
/// What it is for: `lib/game/` is pure maths with no pixels in it, which makes
/// it fast to test and impossible to *look* at. Numbers like gravity, the flap
/// impulse, the scroll speed and the size of the gap can only be judged by
/// feel, and feel needs a screen. This is that screen, and nothing more. It
/// draws the car and the obstacles as bare rectangles, prints the live state,
/// y, velocity and score so the numbers can be read while the thing is moving,
/// and turns taps into `flap()`.
///
/// It reports itself twice, on purpose. On screen there is a text panel, for
/// judging feel while the thing is running. In the log there is one greppable
/// `HARNESS ...` line per change of state or score, for checking a claim
/// afterwards. The second one exists because a screenshot is not a
/// measurement: a pipe drifting across the readout changes the picture without
/// changing the score, so an image cannot tell those two apart and a line of
/// text can. `lib/dev/README.md` has the exact grep.
///
/// It is deliberately crude. The real UI is `lib/ui/`, it is owned by a
/// teammate, and this whole directory gets deleted once that UI renders the
/// model. See `lib/dev/README.md` — including the note there about x and y
/// being stretched independently, which is a known and accepted property of
/// this rig rather than a bug.
library;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
// Brings in Flutter's drawing types AND `debugPrint`, which is what the log
// line below uses. Deliberately not `print`: `debugPrint` throttles its own
// output so that Android's log does not discard lines when something floods it,
// which is the failure mode this whole log line is meant to survive.
import 'package:flutter/widgets.dart';

import 'package:flappymiata/game/game_model.dart';

// -----------------------------------------------------------------------------
// DRAW ORDER — the whole of the fix for "the readout is behind the pipes".
//
// Flame paints sibling components in ascending `priority`: the lowest number
// goes down first and everything after it lands on top of it. So the layer
// that has to stay legible needs the HIGHER number, and these two constants are
// the only place that decision is recorded.
//
// WHY IT HAD TO BE MADE EXPLICIT, given it "looked fine" when it was written:
// the obstacles scroll across the FULL width of the screen, so the readout is
// not tucked away in a safe corner — every single pipe passes over it, once, a
// few seconds after the run starts. The previous version painted the world
// straight onto the canvas AFTER the component tree had already been drawn,
// which put the pipes over the text unconditionally; it only looked correct
// because the first screenshot was taken before the first pipe arrived. An
// ordering that depends on which line of code ran last is invisible. An
// ordering that is a number attached to a layer is not.
// -----------------------------------------------------------------------------

/// Pipes, car and the kill-line markers. Lowest, so it is painted underneath.
const int _worldPriority = 0;

/// The readout and its backing panel. Set far above [_worldPriority] rather
/// than one step above it, so a layer added later has somewhere to sit without
/// anyone having to renumber these.
const int _hudPriority = 100;

void main() {
  final game = HarnessGame();

  // Input via a plain Flutter GestureDetector wrapped around the GameWidget,
  // rather than Flame's own tap mixins: fewer moving parts, and it makes it
  // obvious that the harness is doing the input handling, not the model. The
  // model has no idea what a tap is — it only knows `flap()` and `reset()`.
  runApp(
    GestureDetector(
      behavior: HitTestBehavior.opaque, // taps anywhere, including empty space
      onTap: game.onTapped,
      child: GameWidget<HarnessGame>(game: game),
    ),
  );
}

/// The renderer half. Everything in this class is allowed to import Flame and
/// Flutter; nothing in it is allowed to decide how the game behaves. If a
/// number in here starts affecting gameplay, it belongs in `lib/game/`.
///
/// It owns the model and the two layers that read it — [_WorldLayer] below and
/// [_HudPanel] above. Neither layer holds state of its own: each renders
/// whatever snapshot this class is holding at the moment it is asked to.
class HarnessGame extends FlameGame {
  /// The single source of truth about the run. Reassigned every frame, never
  /// mutated — the model is immutable, so "advance the game" means "replace
  /// the snapshot with the next one".
  ///
  /// The gap pattern is passed explicitly even though it is also the default,
  /// because this is the one place in the app where the injection point is
  /// visible. Swap this line for `(index) => 0.5` and every gap lines up in a
  /// corridor — which is how the harness gets used to check collision by eye.
  GameModel _model = const GameModel.ready(
    gapCentreFor: GameModel.defaultGapCentre,
  );

  late final _HudPanel _hud;

  /// The state and score as they stood when the last `HARNESS` line was
  /// written.
  ///
  /// Nullable so that the very first comparison cannot match. That is what
  /// makes the startup baseline line come out of the same code path as every
  /// later line, rather than being a separate `debugPrint` at the top of
  /// [onLoad] that could drift out of format without anyone noticing.
  RunState? _loggedState;
  int? _loggedScore;

  @override
  Color backgroundColor() => const Color(0xFF0B2545);

  @override
  Future<void> onLoad() async {
    await super.onLoad();

    _hud = _HudPanel();
    // Added in this order for readability only. The priorities carried by the
    // two classes are what actually decide who covers whom, so swapping these
    // two entries changes nothing on screen — which is the point.
    await addAll(<Component>[_WorldLayer(), _hud]);

    // The baseline. A run where the player never taps still has to emit one
    // line, otherwise silence in the log is ambiguous between "nothing
    // happened" and "the harness never started".
    _logIfChanged();
  }

  /// A tap means "flap" during a run and "start again" once the run is over.
  /// The model refuses flaps while dead on its own, so this branch is about
  /// intent, not safety.
  ///
  /// No logging call here: a tap changes the state, and [update] runs within
  /// about 16ms and reports the change then. Keeping one caller for the log is
  /// what keeps the print-on-change rule in a single place.
  void onTapped() {
    _model = _model.state == RunState.dead ? _model.reset() : _model.flap();
  }

  @override
  void update(double dt) {
    super.update(dt);

    // This is the only place real time enters the model. Flame measures the
    // frame; the model just receives a number of seconds. That indirection is
    // why the same physics can be replayed exactly in a test.
    _model = _model.tick(dt);

    _hud.text =
        'state: ${_model.state.name}\n'
        'score: ${_model.score}\n'
        'y:     ${_model.y.toStringAsFixed(4)}\n'
        'vel:   ${_model.velocity.toStringAsFixed(4)}\n'
        'dt:    ${dt.toStringAsFixed(4)}\n'
        'pipes: ${_model.obstacles.length}\n'
        '\n'
        '${_model.state == RunState.dead ? 'tap to reset' : 'tap to flap'}';

    // After the tick, so the line describes the snapshot that is about to be
    // drawn rather than the one that has just left the screen.
    _logIfChanged();
  }

  /// Writes one `HARNESS` line to the log, but only when something worth
  /// reading has actually changed.
  ///
  /// WHY THE LOG EXISTS AT ALL: the on-screen readout can only be checked by a
  /// human looking at a picture, and a picture of this harness is a poor
  /// witness — a pipe drifting across the text changes every pixel of the
  /// readout without changing a single number in the model. A line of text
  /// with the score in it can be grepped, diffed, and pasted into a bug report.
  ///
  /// WHY ONLY ON CHANGE: at 60fps an unconditional print is 3600 lines a
  /// minute. `adb logcat` starts dropping lines under that load, the emulator
  /// visibly slows down, and the one line that mattered is buried among
  /// identical neighbours. Printing on the EDGE turns the log into a list of
  /// events, which is the only form of it that can be read at all.
  ///
  /// WHY THE TRIGGER IS STATE AND SCORE BUT NOT `pipes`: those two are the
  /// facts a run gets judged on. The pipe count rides along on the line as
  /// context — knowing whether an obstacle was on screen when a death happened
  /// is worth having — but it ticks over on its own cadence, roughly every 1.3
  /// seconds, and letting it fire the print would fill an idle run with lines
  /// that say nothing new.
  void _logIfChanged() {
    if (_model.state == _loggedState && _model.score == _loggedScore) {
      return;
    }
    _loggedState = _model.state;
    _loggedScore = _model.score;

    // FIXED FORMAT. This is a grep target, not prose: anything reading the log
    // splits on `=`, so the `HARNESS` tag, the three key names and the single
    // spaces between them are load-bearing. `lib/dev/README.md` documents the
    // exact command, so changing this line means changing that file too.
    debugPrint(
      'HARNESS '
      'state=${_model.state.name} '
      'score=${_model.score} '
      'pipes=${_model.obstacles.length}',
    );
  }
}

/// Everything that scrolls: both pipes of every obstacle, the car, and the two
/// edges that kill. Sits at [_worldPriority], i.e. underneath the readout.
///
/// One component for the whole world rather than one component per obstacle,
/// because `tick` rebuilds the obstacle list from scratch every frame. The
/// model already owns those objects; mirroring them into a component tree would
/// mean adding and removing components 60 times a second in order to display
/// data that is already sitting in a field.
class _WorldLayer extends Component with HasGameReference<HarnessGame> {
  _WorldLayer() : super(priority: _worldPriority);

  @override
  void render(Canvas canvas) {
    _renderObstacles(canvas);
    _renderCar(canvas);

    // Faint lines on the two edges that kill, so the bounds can be seen rather
    // than inferred from the state text flipping to `dead`.
    final Vector2 screen = game.size;
    final edge = Paint()..color = const Color(0x55FFFFFF);
    canvas.drawRect(Rect.fromLTWH(0, 0, screen.x, 2), edge);
    canvas.drawRect(Rect.fromLTWH(0, screen.y - 2, screen.x, 2), edge);
  }

  /// Both pipes of every obstacle, straight from the model's own boxes.
  ///
  /// Drawing [Obstacle.topBox] and [Obstacle.bottomBox] rather than
  /// recomputing the rectangles here is the point of the exercise: what is on
  /// screen is literally what collision is tested against, so a gap that looks
  /// wrong IS wrong. A harness that drew its own idea of a pipe could disagree
  /// with the model and still look convincing.
  void _renderObstacles(Canvas canvas) {
    for (final obstacle in game._model.obstacles) {
      // Dimmed once the obstacle has paid out its point, so scoring can be
      // watched happening instead of inferred from the counter jumping.
      final paint = Paint()
        ..color = obstacle.scored
            ? const Color(0xFF2E6B4F)
            : const Color(0xFF3DDC84);

      canvas.drawRect(_toPixels(obstacle.topBox), paint);
      canvas.drawRect(_toPixels(obstacle.bottomBox), paint);
    }
  }

  /// The car, drawn as its collision box rather than as a nicer-looking sprite.
  /// If the red rectangle is not touching a green one, the model must agree.
  void _renderCar(Canvas canvas) {
    canvas.drawRect(
      _toPixels(game._model.carBox),
      Paint()
        ..color = game._model.state == RunState.dead
            ? const Color(0xFF7A7A7A)
            : const Color(0xFFE23D28),
    );
  }

  /// THE ONE CONVERSION THE MODEL REFUSES TO DO: a normalised box (0..1 on
  /// both axes) becomes pixels by multiplying x by the screen width and y by
  /// the screen height. Resize the window and everything stays at the same
  /// fraction of the playfield, because the model never learned what a pixel
  /// is.
  ///
  /// The two axes are scaled by different numbers, so on a tall phone a shape
  /// that is square in model coordinates is drawn as a tall rectangle. That is
  /// a real distortion and it is accepted here — see `lib/dev/README.md`.
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

/// The text readout on an opaque backing panel, at [_hudPriority] — above
/// everything the world layer draws.
///
/// WHY THE PANEL IS NOT DECORATION: priority alone fixes the ordering, and
/// ordering alone does not fix legibility. White glyphs sitting directly on the
/// bright green of a pipe are a contrast problem rather than a depth one, and
/// they stay hard to read even once they are unmistakably in front. An opaque
/// rectangle underneath makes the background behind the text a known colour no
/// matter what is passing beneath it.
class _HudPanel extends PositionComponent {
  _HudPanel()
    : super(
        // Pushed down from the top edge rather than starting at y = 0: on a
        // phone the first line of text sits directly under the status bar clock
        // and the two overlap into an unreadable smear. 48 logical pixels
        // clears it on the handsets this has been run on.
        position: Vector2(16, 48),
        priority: _hudPriority,
      );

  /// Breathing room between the glyphs and the edge of the panel. Without it
  /// the backing stops exactly at the ink and reads as a highlighter stripe
  /// rather than as a panel.
  static const double _padding = 8.0;

  /// The backing colour. THE ALPHA BYTE IS `FF` AND HAS TO STAY `FF`: the
  /// entire job of this rectangle is that pipe colour cannot show through it.
  /// Any value below full alpha quietly reintroduces the bug this fixed, and it
  /// would only be visible in the few frames a pipe spends behind the text.
  static final Paint _backing = Paint()..color = const Color(0xFF06172E);

  /// Added as a CHILD rather than drawn here, because Flame renders a
  /// component's children after the component itself. That is the same
  /// low-paints-first rule as the two layer priorities above, and it is what
  /// puts the glyphs on top of their own backing instead of under it.
  final TextComponent _readout = TextComponent(
    position: Vector2(_padding, _padding),
    textRenderer: TextPaint(
      style: const TextStyle(
        color: Color(0xFFFFFFFF),
        fontSize: 16.0,
        height: 1.4,
      ),
    ),
  );

  /// Sets the readout, and resizes the panel to match it.
  ///
  /// The panel is measured FROM the text instead of being given a fixed size,
  /// because the readout's width changes with the digits in it — `score: 9` and
  /// `score: 148` are not the same number of pixels wide. A guessed constant is
  /// either padded out with dead space or one character too narrow, and the
  /// too-narrow version puts the end of a line back on top of a pipe.
  set text(String value) {
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
    // zero until the first `text` set and a zero-sized rect draws nothing,
    // which is the right thing to show before there is anything to say.
    canvas.drawRect(Rect.fromLTWH(0, 0, size.x, size.y), _backing);
  }
}
