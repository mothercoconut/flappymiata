/// DISPOSABLE PHYSICS HARNESS — NOT THE GAME'S UI.
///
/// Run it with its own entry point, so `lib/main.dart` never has to change:
///
///     flutter run -t lib/dev/harness.dart
///
/// What it is for: `lib/game/` is pure maths with no pixels in it, which makes
/// it fast to test and impossible to *look* at. Numbers like gravity and the
/// flap impulse can only be judged by feel, and feel needs a screen. This is
/// that screen, and nothing more. It draws a rectangle where the car would be,
/// prints the live state, y and velocity so the numbers can be read while the
/// thing is moving, and turns taps into `flap()`.
///
/// It is deliberately crude. The real UI is `lib/ui/`, it is owned by a
/// teammate, and this whole directory gets deleted once that UI renders the
/// model. See `lib/dev/README.md`.
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
  GameModel _model = const GameModel.ready();

  late final TextComponent _readout;

  static const double _carWidth = 64.0;
  static const double _carHeight = 32.0;

  @override
  Color backgroundColor() => const Color(0xFF0B2545);

  @override
  Future<void> onLoad() async {
    await super.onLoad();

    _readout = TextComponent(
      text: '',
      position: Vector2(16, 16),
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
        'y:     ${_model.y.toStringAsFixed(4)}\n'
        'vel:   ${_model.velocity.toStringAsFixed(4)}\n'
        'dt:    ${dt.toStringAsFixed(4)}\n'
        '\n'
        '${_model.state == RunState.dead ? 'tap to reset' : 'tap to flap'}';
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);

    // THE ONE CONVERSION THE MODEL REFUSES TO DO: normalised y (0..1) becomes
    // a pixel row by multiplying by the current screen height. Resize the
    // window and the car stays at the same fraction of the playfield, because
    // the model never learned what a pixel is.
    final double centreY = _model.y * size.y;
    final double centreX = size.x * 0.3;

    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(centreX, centreY),
        width: _carWidth,
        height: _carHeight,
      ),
      Paint()
        ..color = _model.state == RunState.dead
            ? const Color(0xFF7A7A7A)
            : const Color(0xFFE23D28),
    );

    // Faint lines on the two edges that kill, so the bounds can be seen rather
    // than inferred from the state text flipping to `dead`.
    final edge = Paint()..color = const Color(0x55FFFFFF);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.x, 2), edge);
    canvas.drawRect(Rect.fromLTWH(0, size.y - 2, size.x, 2), edge);
  }
}
