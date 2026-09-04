import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/game/course_seed.dart';
import 'package:flappymiata/game/game_model.dart';
import 'package:flappymiata/game/replay.dart';
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

  // ---------------------------------------------------------------------------
  // PART 5 — the ghost, checked as WIRING rather than as a picture.
  //
  // What a widget test can see: that the game records the run it is playing,
  // that finishing a run leaves a replay behind, that starting the next one
  // puts that replay on the track, and that the ghost advances in step with the
  // live car rather than at some pace of its own.
  //
  // What it CANNOT see: what any of it looks like. Flame paints into a canvas
  // inside one leaf render object, so there is nothing in the widget tree to
  // assert about a translucent teal silhouette. NO EMULATOR OR DEVICE WAS
  // AVAILABLE while this was written, so the ghost's appearance on hardware —
  // its colour, its legibility against the pipes, whether it reads as a ghost
  // at all — is UNVERIFIED. The layering is stated as component priorities
  // (`_worldPriority` < `_ghostPriority` < `_carPriority`) and those numbers are
  // checked by the analyzer and by nothing else.
  // ---------------------------------------------------------------------------

  /// Boots one game on a fixed course and returns it, loaded and ready.
  Future<FlappyMiataGame> boot(WidgetTester tester) async {
    final FlappyMiataGame game = FlappyMiataGame(courseSeed: 0);
    await tester.pumpWidget(GameWidget<FlappyMiataGame>(game: game));
    // Two pumps: the first mounts the widget, the second lets `onLoad` — which
    // decodes the car sprite off the asset bundle — finish before anything is
    // asserted about the game.
    await tester.pump();
    await tester.pump();
    return game;
  }

  /// Runs the game forward by [frames] frames of sixteen milliseconds each.
  Future<void> run(WidgetTester tester, int frames) async {
    for (int i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('a tap starts the run and the run is recorded', (
    WidgetTester tester,
  ) async {
    final FlappyMiataGame game = await boot(tester);
    expect(game.model.state, RunState.ready);
    expect(game.ghostModel, isNull, reason: 'nothing to race on the first run');

    await tester.tapAt(const Offset(200, 400));
    await run(tester, 4);
    expect(game.model.state, RunState.playing);

    // Let the car fall out of the bottom of the playfield. One tap and gravity
    // is about three quarters of a second.
    await run(tester, 120);
    expect(game.model.state, RunState.dead);
  });

  testWidgets('the second run races the first', (WidgetTester tester) async {
    final FlappyMiataGame game = await boot(tester);

    await tester.tapAt(const Offset(200, 400));
    await run(tester, 120);
    expect(game.model.state, RunState.dead, reason: 'the first run has to end');

    // Starting again puts the recorded run on the track.
    await tester.tapAt(const Offset(200, 400));
    await run(tester, 1);
    expect(
      game.ghostModel,
      isNotNull,
      reason: 'the first run left nothing to race',
    );
    expect(game.model.state, RunState.ready,
        reason: 'the restart tap restarts; it does not also flap');
    expect(
      game.ghostModel!.state,
      RunState.ready,
      reason: 'the ghost waits on the start line until the live run begins',
    );

    // Now drive the second run and check the ghost follows the same trajectory
    // the first one did — it is the same recording, on the same course, so it
    // has to.
    await tester.tapAt(const Offset(200, 400));
    await run(tester, 30);
    expect(game.model.state, RunState.playing);
    expect(game.ghostModel!.state, isNot(RunState.ready),
        reason: 'the ghost set off when the live run did');

    // The ghost is a genuine replay of the first run, not a second live
    // simulation: its y at this point must be a y the recorded run really
    // visited.
    final Set<double> recordedYs = <double>{
      for (final GameModel m in replayTrace(
        Replay(
          seed: 0,
          tapFrames: <int>[0],
          frames: 400,
        ),
      ))
        m.y,
    };
    expect(
      recordedYs.contains(game.ghostModel!.y),
      isTrue,
      reason: 'the ghost is somewhere the recorded run never was',
    );
  });

  testWidgets('the game plays the daily course by default', (
    WidgetTester tester,
  ) async {
    // The wiring for Part 4: the seed the app actually plays is today's, and
    // the calendar is read here rather than inside `lib/game/`.
    final DateTime now = DateTime.now();
    expect(kDailyChallenge, isTrue);
    expect(todaysCourseSeed(), dailySeed(now.year, now.month, now.day));

    final FlappyMiataGame game = FlappyMiataGame();
    expect(game.courseSeed, todaysCourseSeed());
    expect(game.courseSeed, isNot(classicCourseSeed));
  });
}
