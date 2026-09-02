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
/// It is deliberately crude. The real UI is `lib/ui/`, it is owned by a
/// teammate, and this whole directory gets deleted once that UI renders the
/// model. See `lib/dev/README.md` — including the note there about x and y
/// being stretched independently, which is a known and accepted property of
/// this rig rather than a bug.
library;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/widgets.dart';

import 'package:flappymiata/game/game_model.dart';

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

  late final TextComponent _readout;

  @override
  Color backgroundColor() => const Color(0xFF0B2545);

  @override
  Future<void> onLoad() async {
    await super.onLoad();

    _readout = TextComponent(
      // Pushed down from the top edge rather than starting at y = 0: on a
      // phone the first line of text sits directly under the status bar clock
      // and the two overlap into an unreadable smear. 48 logical pixels clears
      // it on the handsets this has been run on.
      position: Vector2(16, 48),
      textRenderer: TextPaint(
        style: const TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 16.0,
          height: 1.4,
        ),
      ),
    );
    await add(_readout);
  }

  /// A tap means "flap" during a run and "start again" once the run is over.
  /// The model refuses flaps while dead on its own, so this branch is about
  /// intent, not safety.
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

    _readout.text =
        'state: ${_model.state.name}\n'
        'score: ${_model.score}\n'
        'y:     ${_model.y.toStringAsFixed(4)}\n'
        'vel:   ${_model.velocity.toStringAsFixed(4)}\n'
        'dt:    ${dt.toStringAsFixed(4)}\n'
        'pipes: ${_model.obstacles.length}\n'
        '\n'
        '${_model.state == RunState.dead ? 'tap to reset' : 'tap to flap'}';
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);

    _renderObstacles(canvas);
    _renderCar(canvas);

    // Faint lines on the two edges that kill, so the bounds can be seen rather
    // than inferred from the state text flipping to `dead`.
    final edge = Paint()..color = const Color(0x55FFFFFF);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.x, 2), edge);
    canvas.drawRect(Rect.fromLTWH(0, size.y - 2, size.x, 2), edge);
  }

  /// Both pipes of every obstacle, straight from the model's own boxes.
  ///
  /// Drawing [Obstacle.topBox] and [Obstacle.bottomBox] rather than
  /// recomputing the rectangles here is the point of the exercise: what is on
  /// screen is literally what collision is tested against, so a gap that looks
  /// wrong IS wrong. A harness that drew its own idea of a pipe could disagree
  /// with the model and still look convincing.
  void _renderObstacles(Canvas canvas) {
    for (final obstacle in _model.obstacles) {
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
      _toPixels(_model.carBox),
      Paint()
        ..color = _model.state == RunState.dead
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
  Rect _toPixels(Box box) => Rect.fromLTRB(
    box.left * size.x,
    box.top * size.y,
    box.right * size.x,
    box.bottom * size.y,
  );
}
