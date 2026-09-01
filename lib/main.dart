import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/layout.dart';
import 'package:flutter/widgets.dart';

/// Entry point. Flame games are just a widget, so there is no MaterialApp and
/// no Scaffold here — [GameWidget] owns the whole screen and drives its own
/// render loop.
void main() {
  runApp(const FlappyMiataApp());
}

/// THIS FILE IS DELIBERATELY THIN.
///
/// Why: this is a two-person repo and `lib/main.dart` is the one file both of
/// us have to touch, so every line added here is a line that can collide on
/// merge. Its job is wiring only — start the app, hand Flutter a game. Actual
/// gameplay (player, obstacles, collisions, scoring) belongs in `lib/game/`,
/// and menus/HUD in `lib/ui/`, where one person can own a file outright.
/// If you are about to add behaviour here, add it in `lib/game/` instead.
class FlappyMiataApp extends StatelessWidget {
  const FlappyMiataApp({super.key});

  @override
  Widget build(BuildContext context) {
    // `.controlled` lets the widget's own State create and keep the game
    // instance. Building `GameWidget(game: FlappyMiataGame())` directly would
    // construct a fresh game on every rebuild and throw away its state.
    return const GameWidget<FlappyMiataGame>.controlled(
      gameFactory: FlappyMiataGame.new,
    );
  }
}

/// Scaffold game: proves the Flame engine is wired up and boots on a device.
/// Nothing here is gameplay — it is the "hello world" that tells us the render
/// loop is running before anyone builds on top of it.
class FlappyMiataGame extends FlameGame {
  /// Painted every frame before any component renders. A flat colour is enough
  /// to show the loop is alive: if this colour is on screen, Flame is drawing.
  @override
  Color backgroundColor() => const Color(0xFF0B2545);

  @override
  Future<void> onLoad() async {
    await super.onLoad();

    // AlignComponent sizes itself to its parent (the game) and repositions its
    // child whenever that size changes, so the label stays centred when the
    // device rotates. Setting `position: size / 2` once would centre it only
    // for the size the game happened to have at load time.
    await add(
      AlignComponent(
        alignment: Anchor.center,
        child: TextComponent(text: 'flappymiata'),
      ),
    );
  }
}
