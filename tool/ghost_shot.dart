/// Writes PNGs of a real frame with a real ghost on it, with no device.
///
///     flutter test tool\ghost_shot.dart
///
/// Four files land in `build\` (which is gitignored and analyzer-excluded, so
/// nothing here can leave litter in the repository):
///
///     build\ghost-on.png       a whole frame, phone-shaped, ghost shown
///     build\ghost-off.png      the identical frame with GHOST: OFF
///     build\ghost-on-zoom.png  the two cars, cropped and magnified 4x
///     build\ghost-off-zoom.png the same crop with the ghost hidden
///
/// ============================================================================
/// WHY THIS IS A TOOL AND NOT A TEST, AND WHY IT IS RUN BY `flutter test`
/// ============================================================================
///
/// It asserts almost nothing. `test/ghost_render_test.dart` is the test — it
/// reads the same pixels and makes claims about them that can go red. This one
/// answers the other half of the question, the half no assertion can reach:
/// what does it LOOK like. A person has to answer that, and until now the only
/// way to put the question in front of a person was to install the app on a
/// phone and play well enough to record a run worth replaying.
///
/// It lives in `tool/` so that a bare `flutter test` — which only walks `test/`
/// — never runs it and never writes a file. It is *invoked* through
/// `flutter test` because rasterising a canvas needs a Flutter engine under it,
/// which a bare `dart run` does not have. That is the same reason
/// `test/sprite_colours.dart` cannot be used by `tool/palette_report.dart`.
///
/// ============================================================================
/// WHAT THE PICTURE IS AND IS NOT
/// ============================================================================
///
/// IS: the shipped `render`, the shipped layer priorities, the shipped paints,
/// the shipped geometry, at a phone-shaped 1080x2400, on a course somebody
/// could really be playing, with a ghost from a run somebody could really have
/// recorded.
///
/// IS NOT: a photograph of a phone. It is a still, so it says nothing about how
/// the two cars read while they are MOVING — which is exactly the axis the
/// original complaint was about. It is also rendered by the host machine's
/// rasteriser rather than a phone's GPU, so fine antialiasing may differ by a
/// pixel. Treat it as a very good proof sheet and not as a substitute for
/// looking at the thing.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/game.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/game/game_model.dart';
import 'package:flappymiata/game/replay.dart';
import 'package:flappymiata/game/run_code.dart';
import 'package:flappymiata/main.dart';
import 'package:flappymiata/ui/high_score_store.dart';

import 'ghost_run.dart';

/// The surface the frames are drawn at.
///
/// The aspect a real phone gives this game, and the one `GameModel` says its
/// collision boxes were designed at — `referenceAspect` is literally
/// `2400 / 1080`. Rendering at anything else would make the cars the wrong
/// shape and the proof sheet a picture of a game nobody plays.
const Size deviceSize = Size(1080, 2400);

/// How much the close-up is magnified.
const double zoom = 4.0;

/// Where the files go. Gitignored, and excluded from the analyzer.
const String outputDirectory = 'build';

void main() {
  testWidgets('write the proof sheet', (WidgetTester tester) async {
    tester.view.physicalSize = deviceSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final Replay best = recordSolverRun(seed: 0, targetScore: 8);
    final BestRun record = bestRunFromCode(encodeRunCode(best))!;

    final FlappyMiataGame game = FlappyMiataGame(
      courseSeed: best.seed,
      highScoreStore: InMemoryHighScoreStore(record),
    );
    await tester.pumpWidget(GameWidget<FlappyMiataGame>(game: game));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // The car sprite is decoded on a real I/O future that a `pump()` inside the
    // fake-async zone never advances — see `test/ghost_render_test.dart`, where
    // getting this wrong produced a frame with no car in it.
    await tester.runAsync(() async {
      for (int i = 0; i < 2000 && game.carImage == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    });
    if (game.carImage == null) {
      throw StateError('the car sprite never decoded');
    }

    // One tap, then hands off, so the live car falls away from the ghost and
    // the two are far enough apart in the picture to be compared side by side.
    // Stop on the first frame where they are clear of each other — the same
    // rule `test/ghost_render_test.dart` uses, and for the same reason.
    game.startRun();
    Rect? live;
    Rect? ghostRect;
    for (int i = 0; i < 200; i++) {
      game.update(replayFrameSeconds);
      final GameModel? ghost = game.ghostModel;
      if (game.model.state != RunState.playing) break;
      if (ghost == null || ghost.state != RunState.playing) continue;
      final Rect a = carFootprint(game.model.carBox, game.size);
      final Rect b = carFootprint(ghost.carBox, game.size);
      if (a.inflate(8).overlaps(b.inflate(8))) continue;
      live = a;
      ghostRect = b;
      break;
    }
    if (live == null || ghostRect == null) {
      throw StateError('never reached a frame with the two cars apart');
    }

    // The crop: both cars plus a generous margin, so the pipes and sky they are
    // being told apart AGAINST are in the picture too. A close-up of two cars
    // on a blank background would flatter the design.
    final Rect crop = live.expandToInclude(ghostRect).inflate(90);

    Directory(outputDirectory).createSync(recursive: true);

    for (final bool shown in <bool>[true, false]) {
      if (game.ghostEnabled != shown) game.toggleGhost();

      final ui.PictureRecorder recorder = ui.PictureRecorder();
      game.render(Canvas(recorder));
      final ui.Picture frame = recorder.endRecording();

      // The close-up is the SAME picture drawn through a scale, not a second
      // render at a different size. A re-render could differ from the full
      // frame; a transform of one picture cannot.
      final ui.PictureRecorder closeRecorder = ui.PictureRecorder();
      final Canvas close = Canvas(closeRecorder);
      close.scale(zoom);
      close.translate(-crop.left, -crop.top);
      close.drawPicture(frame);
      final ui.Picture magnified = closeRecorder.endRecording();

      await _writePng(tester, frame, deviceSize.width.round(),
          deviceSize.height.round(), 'ghost-${shown ? 'on' : 'off'}.png');
      await _writePng(
        tester,
        magnified,
        (crop.width * zoom).round(),
        (crop.height * zoom).round(),
        'ghost-${shown ? 'on' : 'off'}-zoom.png',
      );

      frame.dispose();
      magnified.dispose();
    }

    // ignore: avoid_print
    print('score on the recorded run: ${replayFinalModel(best).score}\n'
        'live car at  $live\n'
        'ghost at     $ghostRect\n'
        'close-up     $crop at ${zoom}x');
  });
}

/// Rasterises [picture] and writes it into [outputDirectory] as [name].
///
/// `runAsync` for the same reason `test/ghost_render_test.dart` needs it: a
/// `testWidgets` body runs inside a fake-async zone, and a rasterisation future
/// is completed by an engine thread the fake clock never reaches. Without it
/// this does not fail — it simply never returns.
Future<void> _writePng(
  WidgetTester tester,
  ui.Picture picture,
  int width,
  int height,
  String name,
) async {
  final Uint8List? png = await tester.runAsync<Uint8List>(() async {
    final ui.Image image = await picture.toImage(width, height);
    final ByteData? data =
        await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) {
      throw StateError('$name rasterised but produced no PNG bytes');
    }
    return data.buffer.asUint8List();
  });
  if (png == null) {
    throw StateError('$name was never rasterised');
  }
  final File file = File('$outputDirectory${Platform.pathSeparator}$name');
  file.writeAsBytesSync(png);
  // ignore: avoid_print
  print('wrote ${file.path}  ${width}x$height  ${png.length} bytes');
}
