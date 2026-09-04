/// The ghost, checked as a PICTURE rather than as wiring.
///
/// ============================================================================
/// WHY THIS FILE EXISTS, AND WHAT IT IS AN ANSWER TO
/// ============================================================================
///
/// `test/widget_test.dart` says, in its own words, what could not be checked
/// before this: "Flame paints into a canvas inside one leaf render object, so
/// there is nothing in the widget tree to assert about a translucent teal
/// silhouette... the ghost's appearance on hardware — its colour, its
/// legibility against the pipes, whether it reads as a ghost at all — is
/// UNVERIFIED."
///
/// It stayed unverified, and a player eventually reported the consequence: the
/// ghost drew the same car sprite as the live car, filled, so two identical car
/// shapes were moving at speed and he could not tell which one was his. Every
/// test in the suite was green throughout, and rightly — they all check where
/// the ghost IS, and none of them could see what it LOOKS LIKE.
///
/// The gap was never really "a widget test cannot see a canvas". It is that
/// nobody had asked the canvas. A `PictureRecorder` takes the game's own
/// `render` — the same call the `GameWidget` makes sixty times a second — and
/// turns it into pixels a test can read.
///
/// ============================================================================
/// THE TRICK THAT MAKES THIS ROBUST: DIFFERENCE, NOT COLOUR MATCHING
/// ============================================================================
///
/// The obvious version of this test looks for teal pixels, and it would be a
/// bad test: the ghost is translucent, so its colour on screen is a blend with
/// whatever is behind it, and behind it is a vertical sky gradient with hills,
/// clouds and scrolling pipes in front of that. "Close enough to teal" would
/// need a tolerance, and a tolerance is a number that gets widened until the
/// test passes.
///
/// So the same frame is rendered TWICE — once with the ghost shown, once with
/// it hidden — and the pixels that differ between the two are, by construction,
/// exactly the pixels the ghost painted. No tolerance, no colour arithmetic,
/// and nothing to tune. It also means the toggle is being exercised as the same
/// assertion: if `GHOST: OFF` did not really stop the drawing, there would be
/// no difference to measure.
///
/// ============================================================================
/// WHAT THIS PROVES, AND WHAT IT STILL DOES NOT
/// ============================================================================
///
/// PROVES: the ghost is drawn; it is drawn only inside the rectangle the
/// recorded car occupied; the middle of that rectangle is left alone, so it is
/// an outline and not a filled shape; ink appears on all four sides, so it is a
/// closed outline and not a stray mark; hiding it removes every one of those
/// pixels and touches nothing else on the frame; and none of it changes the run.
///
/// DOES NOT PROVE: that it looks good, that it is legible on a phone in
/// daylight, or that a player can tell the two cars apart. Those are judgements
/// about a moving image and there is no test in this repository — or, as far as
/// the last one goes, in this field — that can make them. What this file can do
/// is make the specific defect that was reported impossible to reintroduce
/// without something going red: a filled ghost fails the interior check on the
/// first run of the suite.
library;

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

import '../tool/ghost_run.dart';

/// One frame at 60fps, the timestep every replay is stated in.
const double frame = replayFrameSeconds;

/// The recorded run everything below is raced against.
///
/// Built by `tool/ghost_run.dart` — the same command that prints the run code a
/// person pastes into `--dart-define=BEST_RUN=` to watch the ghost by hand. The
/// fixture and the thing a human looks at are therefore the same artefact, so a
/// change that made one of them unusable cannot leave the other looking fine.
///
/// Eight obstacles rather than the tool's default twelve: this has to be a real
/// run that flies over real pipes for several seconds, and nothing here gets
/// better for the extra ten seconds of solving time on every run of the suite.
Replay ghostFixture() => recordSolverRun(seed: 0, targetScore: 8);

/// Boots a game that already holds [best] as its record, and lets `onLoad`
/// settle.
///
/// The store is seeded through [bestRunFromCode], which is the same function
/// `--dart-define=BEST_RUN=` goes through in `lib/main.dart`. So this test boots
/// the app in exactly the state that flag produces, rather than in a state only
/// a test can reach.
Future<FlappyMiataGame> boot(WidgetTester tester, Replay best) async {
  final BestRun? record = bestRunFromCode(encodeRunCode(best));
  expect(record, isNotNull, reason: 'the fixture does not encode to a run code');

  final FlappyMiataGame game = FlappyMiataGame(
    courseSeed: best.seed,
    highScoreStore: InMemoryHighScoreStore(record),
  );
  await tester.pumpWidget(GameWidget<FlappyMiataGame>(game: game));
  // Mount, let `onLoad` settle, and let the asynchronous best-run load land.
  await tester.pump();
  await tester.pump();
  await tester.pump();

  // AND WAIT FOR THE CAR SPRITE, which the three pumps above do NOT cover and
  // which cost this file an hour to work out.
  //
  // `onLoad` deliberately does not await the sprite — see `lib/main.dart` on
  // why a game must not be held up by an image — so it is decoded on a real
  // I/O future. A `pump()` runs inside the fake-async zone and never advances
  // one. The first version of this file therefore photographed a frame with no
  // car in it, then took the second photograph inside a `runAsync` that let the
  // decode finish, and read the car that had just appeared as if it were the
  // ghost: 2159 stray pixels, in a perfect car shape, 38 pixels below the
  // ghost.
  //
  // A bounded spin rather than a fixed sleep, because "50ms is surely enough"
  // is a flake waiting for a slower machine.
  await tester.runAsync(() async {
    for (int i = 0; i < 2000 && game.carImage == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  });
  expect(game.carImage, isNotNull,
      reason: 'the car sprite never decoded, so every frame photographed below '
          'is a frame with no live car in it');
  return game;
}

/// Advances the game by exactly [frames] fixed steps.
///
/// `game.update` directly rather than pumping the tester, for the reason
/// `test/game_screens_test.dart` gives: handing the accumulator exactly one
/// frame's worth leaves a carry of zero, so the step count is a fact rather
/// than an expectation.
void advance(FlappyMiataGame game, int frames) {
  for (int i = 0; i < frames; i++) {
    game.update(frame);
  }
}

/// One rendered frame, as raw RGBA plus the size it was rasterised at.
class Shot {
  /// Four bytes per pixel, row by row.
  final Uint8List pixels;

  final int width;
  final int height;

  const Shot(this.pixels, this.width, this.height);

  /// The packed 0xAARRGGBB at ([x], [y]).
  int at(int x, int y) {
    final int i = (y * width + x) * 4;
    return (pixels[i + 3] << 24) |
        (pixels[i] << 16) |
        (pixels[i + 1] << 8) |
        pixels[i + 2];
  }
}

/// Renders [game] exactly as the `GameWidget` would, and reads the pixels back.
///
/// `game.render` is the real entry point — for a game with no parent it calls
/// `renderTree`, which draws every layer in priority order. So this is the
/// shipped draw order, the shipped paints and the shipped geometry, not a
/// reconstruction of them.
///
/// THE `runAsync` IS LOAD-BEARING AND IS NOT DECORATION. A `testWidgets` body
/// runs inside a fake-async zone where time only moves when the test says so,
/// and rasterising a `Picture` is real work done on a real engine thread. Its
/// future is therefore completed by something the fake clock never reaches:
/// without this, the call does not fail, it simply never returns, and the test
/// dies ten minutes later on the harness timeout — which is what the first
/// version of this file did. `runAsync` steps outside the fake zone for exactly
/// the two calls that need it.
Future<Shot> shoot(WidgetTester tester, FlappyMiataGame game) async {
  final int width = game.size.x.round();
  final int height = game.size.y.round();
  expect(width, greaterThan(0), reason: 'the game was never given a size');

  // Recorded inside the fake zone, because drawing is synchronous and has to
  // see the game in exactly the state the test left it in.
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  game.render(Canvas(recorder));
  final ui.Picture picture = recorder.endRecording();

  final Shot? shot = await tester.runAsync(() async {
    final ui.Image image = await picture.toImage(width, height);
    final ByteData? raw =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    if (raw == null) {
      throw StateError('the rendered frame could not be read back');
    }
    return Shot(raw.buffer.asUint8List(), width, height);
  });
  picture.dispose();

  if (shot == null) {
    throw StateError('the frame was never rasterised');
  }
  return shot;
}

/// Every pixel that is not the same in [a] and [b].
List<Offset> difference(Shot a, Shot b) {
  expect(a.width, b.width);
  expect(a.height, b.height);
  final List<Offset> out = <Offset>[];
  for (int y = 0; y < a.height; y++) {
    for (int x = 0; x < a.width; x++) {
      if (a.at(x, y) != b.at(x, y)) {
        out.add(Offset(x.toDouble(), y.toDouble()));
      }
    }
  }
  return out;
}

void main() {
  testWidgets('the ghost is an outline, and hiding it removes exactly that', (
    WidgetTester tester,
  ) async {
    final Replay best = ghostFixture();
    expect(replayFinalModel(best).score, greaterThan(0),
        reason: 'the fixture never passed an obstacle, so the ghost being '
            'rendered below is a car that fell off the screen');

    final FlappyMiataGame game = await boot(tester, best);
    expect(game.ghostEnabled, isTrue,
        reason: 'the ghost has to ship ON, or this test is checking the '
            'wrong default');
    expect(game.ghostModel, isNotNull,
        reason: 'the seeded record never came back as a ghost');

    // ------------------------------------------------------------------------
    // Find a frame worth photographing.
    //
    // The live run gets ONE tap — the one that starts it — and then falls,
    // while the ghost keeps flying the recorded run. That is what pulls the two
    // apart. A frame is usable when both cars are on screen, the live run is
    // still alive, and the two footprints do not touch: where they overlap the
    // live car is drawn on top (`_carPriority` > `_ghostPriority`), so the
    // ghost's ink would be hidden there and "the outline is closed on all four
    // sides" would be a claim about pixels nothing drew.
    // ------------------------------------------------------------------------
    game.startRun();

    Rect? live;
    Rect? ghost;
    final Rect screen = Rect.fromLTWH(0, 0, game.size.x, game.size.y);
    for (int i = 0; i < 200; i++) {
      advance(game, 1);
      final GameModel? ghostModel = game.ghostModel;
      if (game.model.state != RunState.playing) break;
      if (ghostModel == null || ghostModel.state != RunState.playing) continue;

      final Rect liveRect = carFootprint(game.model.carBox, game.size);
      final Rect ghostRect = carFootprint(ghostModel.carBox, game.size);
      if (!screen.deflate(4).contains(liveRect.topLeft) ||
          !screen.deflate(4).contains(liveRect.bottomRight) ||
          !screen.deflate(4).contains(ghostRect.topLeft) ||
          !screen.deflate(4).contains(ghostRect.bottomRight)) {
        continue;
      }
      if (liveRect.inflate(4).overlaps(ghostRect.inflate(4))) continue;

      live = liveRect;
      ghost = ghostRect;
      break;
    }

    expect(ghost, isNotNull,
        reason: 'no frame was reached with both cars on screen and apart, so '
            'nothing below was measured');
    final Rect ghostRect = ghost!;
    final Rect liveRect = live!;

    // ------------------------------------------------------------------------
    // The two photographs. Nothing between them advances the game, so the only
    // difference is the setting.
    // ------------------------------------------------------------------------
    final Shot withGhost = await shoot(tester, game);
    game.toggleGhost();
    expect(game.ghostEnabled, isFalse);
    final Shot withoutGhost = await shoot(tester, game);
    game.toggleGhost();

    final List<Offset> ink = difference(withGhost, withoutGhost);

    // 1. IT DRAWS. Also the toggle, end to end: with no difference at all,
    //    either the ghost was never painted or `GHOST: OFF` does not stop it,
    //    and the two are indistinguishable from here.
    expect(ink, isNotEmpty,
        reason: 'the ghost painted nothing, or hiding it changed nothing');

    // 2. IT DRAWS ONLY WHERE THE RECORDED CAR WAS. Inflated by two pixels for
    //    the antialiased rim of the stroke, which is genuinely outside the
    //    path it is drawn on.
    final Rect allowed = ghostRect.inflate(2);
    final List<Offset> strays =
        ink.where((Offset p) => !allowed.contains(p)).toList();
    expect(strays, isEmpty,
        reason: '${strays.length} pixels changed outside the ghost\'s own '
            'footprint, the first at ${strays.isEmpty ? '' : strays.first} — '
            'the ghost is painting somewhere the recorded car never was');

    // 3. THE MIDDLE IS EMPTY. This is the assertion the player's report bought.
    //    A filled silhouette — which is what the ghost used to be — covers the
    //    centre of its own footprint, so this fails the moment anyone puts the
    //    fill back.
    //
    //    The region is the middle 60% by 40% rather than the whole interior, so
    //    the rounded corners of the outline have room and the check does not
    //    depend on the exact corner radius. It is far larger than any stroke
    //    could reach and far smaller than any fill could avoid.
    final Rect middle = Rect.fromCenter(
      center: ghostRect.center,
      width: ghostRect.width * 0.6,
      height: ghostRect.height * 0.4,
    );
    final List<Offset> filled =
        ink.where((Offset p) => middle.contains(p)).toList();
    expect(filled, isEmpty,
        reason: '${filled.length} pixels in the middle of the ghost were '
            'painted, so it is a filled shape and not an outline — which is '
            'the defect a player reported: two car-shaped masses on screen at '
            'once');

    // 4. IT IS A CLOSED OUTLINE, not one edge or a stray tick. Each side is the
    //    outer eighth of the footprint on that axis, which the stroke reaches
    //    and the empty middle does not.
    bool inkIn(bool Function(Offset) where) => ink.any(where);
    expect(inkIn((Offset p) => p.dy <= ghostRect.top + ghostRect.height / 8),
        isTrue, reason: 'nothing drawn along the top of the ghost');
    expect(inkIn((Offset p) => p.dy >= ghostRect.bottom - ghostRect.height / 8),
        isTrue, reason: 'nothing drawn along the bottom of the ghost');
    expect(inkIn((Offset p) => p.dx <= ghostRect.left + ghostRect.width / 8),
        isTrue, reason: 'nothing drawn down the left of the ghost');
    expect(inkIn((Offset p) => p.dx >= ghostRect.right - ghostRect.width / 8),
        isTrue, reason: 'nothing drawn down the right of the ghost');

    // 5. THE LIVE CAR IS UNTOUCHED. Stated separately from (2) even though it
    //    follows from it, because it is the half a reader actually cares about:
    //    a display setting for the ghost must not be able to change the car the
    //    player is steering.
    for (double y = liveRect.top; y < liveRect.bottom; y++) {
      for (double x = liveRect.left; x < liveRect.right; x++) {
        expect(withGhost.at(x.toInt(), y.toInt()),
            withoutGhost.at(x.toInt(), y.toInt()),
            reason: 'the live car changed when the ghost was hidden, at '
                '($x, $y)');
      }
    }

    // ignore: avoid_print
    print('ghost ink: ${ink.length} px inside a '
        '${ghostRect.width.toStringAsFixed(1)}x'
        '${ghostRect.height.toStringAsFixed(1)} footprint '
        '(${(100 * ink.length / (ghostRect.width * ghostRect.height)).toStringAsFixed(1)}% '
        'of it), middle empty');
  });

  testWidgets('hiding the ghost changes no run', (WidgetTester tester) async {
    // THE CLAIM THE WHOLE SETTING RESTS ON, and the same one
    // `test/assist_test.dart` and `test/reduced_motion_test.dart` make about
    // theirs: this is a display setting, so a run played with it on and the
    // same run played with it off are the same run.
    //
    // It is not a foregone conclusion. The ghost is a second `ReplayPlayer`
    // being stepped inside the same loop as the live run, and switching it off
    // is precisely the change somebody would be tempted to implement by not
    // stepping it — which would be free until the day the two loops shared
    // anything.
    final Replay best = ghostFixture();

    final FlappyMiataGame shown = await boot(tester, best);
    final FlappyMiataGame hidden = await boot(tester, best);
    hidden.toggleGhost();
    expect(hidden.ghostEnabled, isFalse);
    expect(shown.ghostEnabled, isTrue);

    // The same input on both: the run's own recorded taps, replayed as taps on
    // the live game. A run driven this way really flies rather than falling off
    // the start line, so the comparison below is between two runs that went
    // somewhere.
    final Set<int> taps = best.tapFrames.toSet();
    for (int i = 0; i < best.frames; i++) {
      if (taps.contains(i)) {
        shown.startRun();
        hidden.startRun();
      }
      advance(shown, 1);
      advance(hidden, 1);
    }

    expect(shown.score, greaterThan(0), reason: 'neither run went anywhere');
    expect(hidden.model, shown.model,
        reason: 'the same taps gave a different run with the ghost hidden');
    expect(hidden.score, shown.score);
    expect(hidden.riskScore, shown.riskScore);

    // And the replay really was still running underneath, so switching it back
    // on mid-race shows the ghost where the recording is — not where it was
    // when it was switched off.
    expect(hidden.ghostModel, isNotNull);
    expect(hidden.ghostModel!.y, shown.ghostModel!.y,
        reason: 'the hidden ghost stopped being stepped, so turning it back on '
            'would drop it into the race several seconds behind');
  });

  group('seeding a best run from a code', () {
    // `--dart-define=BEST_RUN=` cannot be set from inside `flutter test`, so
    // the flag itself is unreachable here. What IS reachable — and is the only
    // part with any logic in it — is the function the flag goes through.

    test('a real run code comes back as a record that scores what it scores',
        () {
      final Replay best = ghostFixture();
      final String code = encodeRunCode(best);
      final BestRun? record = bestRunFromCode(code);

      expect(record, isNotNull);
      expect(record!.code, code);
      // RE-DERIVED, not asserted from the same number twice: the record's score
      // has to be what re-executing the run produces, because that is what the
      // start screen will show beside the ghost this seeds.
      expect(record.score, replayFinalModel(best).score);
      expect(record.score, greaterThan(0));
      expect(record.replay, best,
          reason: 'the seeded ghost is a different run from the one asked for');
    });

    test('the course comes out of the code, so one flag is enough', () {
      // The failure this rules out is silent: a seeded run on a course the game
      // is not playing simply does not appear, which looks exactly like the
      // rendering bug somebody set the flag to go and look at.
      final Replay best = ghostFixture();
      final BestRun record = bestRunFromCode(encodeRunCode(best))!;
      expect(record.replay!.seed, best.seed);
    });

    test('an absent or unreadable code is nothing at all, not a crash', () {
      // The ordinary build takes the first of these on every launch:
      // `String.fromEnvironment` with no define is the empty string.
      expect(bestRunFromCode(''), isNull);
      expect(bestRunFromCode('NOTARUNCODE'), isNull);
      expect(bestRunFromCode('!!!'), isNull);
    });

    test('an ordinary build seeds nothing', () {
      // The whole feature is supposed to be absent unless somebody asks for it,
      // and this is the assertion that says so about the build the tests run
      // in — which is the same build, in this respect, as the shipped one.
      expect(kSeededBestRun, isEmpty);
      expect(seededBestRun, isNull);
    });
  });
}
