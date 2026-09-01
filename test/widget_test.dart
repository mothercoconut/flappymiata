import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/main.dart';

void main() {
  testWidgets('app boots with a Flame GameWidget in the tree', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const FlappyMiataApp());

    // WHY THIS ASSERTION AND NOT `find.text('flappymiata')`:
    //
    // Flame does not build Flutter widgets for the things it draws. A
    // TextComponent is painted onto a canvas inside a single leaf render
    // object, so it never appears in the widget tree at all — `find.text`
    // would report `findsNothing` no matter how correct the game is. A test
    // written that way would fail on working code, or (worse) be "fixed" by
    // deleting the assertion and then pass forever without checking anything.
    //
    // What CAN be observed from a widget test is the wiring: that main.dart
    // actually hands Flutter a GameWidget. That is what this scaffold is for.
    //
    // Note the explicit type argument. `find.byType` matches on exact
    // runtimeType, and a bare `GameWidget` means `GameWidget<dynamic>`, which
    // would never match the `GameWidget<FlappyMiataGame>` main.dart builds.
    expect(find.byType(GameWidget<FlappyMiataGame>), findsOneWidget);
  });
}
