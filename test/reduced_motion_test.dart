/// Reduced motion: that it stops the decoration, and that it stops NOTHING
/// else.
///
/// ============================================================================
/// THE SECOND HALF IS THE IMPORTANT HALF
/// ============================================================================
///
/// It is easy to write a reduced-motion mode that works. It is easy, and common,
/// to write one that quietly becomes an easy mode — slower scrolling, wider
/// gaps, a more forgiving hitbox — because "less motion" and "less difficulty"
/// sound adjacent when you say them quickly. They are not adjacent. A player
/// who turns this on is saying the scenery makes them ill, not that the game is
/// too hard, and handing them a different, easier game is taking away the thing
/// they came for.
///
/// So the central test here is not "does the parallax stop". It is: play a
/// whole recorded run twice, once with motion reduced and once without, and
/// require the two to be identical FRAME FOR FRAME — the model, the score and
/// the risk score. That is the same shape as the assertion
/// `test/assist_test.dart` makes about assist mode, for the same reason: both
/// are display settings, and a display setting that could reach the model would
/// break the replay system, the verified score and the fairness proof at once.
///
/// ============================================================================
/// WHAT IS NOT CHECKED HERE
/// ============================================================================
///
/// No emulator or device was available. That the parallax LOOKS like depth,
/// that stopping it actually helps somebody with a vestibular disorder, and
/// that the three-state control is discoverable, are all unverified. What is
/// checked is that the clock stops, that the offsets stop with it, that the
/// platform's own switch is obeyed, and that none of it touches the run.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/game.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/game/game_model.dart';
import 'package:flappymiata/main.dart';
import 'package:flappymiata/ui/game_screens.dart';
import 'package:flappymiata/ui/high_score_store.dart';
import 'package:flappymiata/ui/motion.dart';

import '../tool/fairness.dart';

/// One frame at 60fps.
const double frame = 1.0 / 60.0;

/// A host that records nothing but what it was asked to do.
class _Host implements GameScreenHost {
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);
  final List<String> calls = <String>[];

  @override
  Listenable get revision => _revision;
  @override
  int score = 0;
  @override
  int riskScore = 0;
  @override
  int bestScore = 0;
  @override
  bool hasBestScore = false;
  @override
  bool isNewBest = false;
  @override
  bool paused = false;
  @override
  bool assistEnabled = false;
  @override
  MotionSetting motionSetting;
  @override
  bool systemDisablesAnimations;

  _Host({
    this.motionSetting = MotionSetting.system,
    this.systemDisablesAnimations = false,
  });

  @override
  void toggleAssist() => calls.add('assist');
  @override
  void cycleMotion() => calls.add('motion');
  @override
  void startRun() => calls.add('start');
  @override
  void pauseRun() => calls.add('pause');
  @override
  void resumeRun() => calls.add('resume');
  @override
  void restartRun() => calls.add('restart');
}

/// A [MotionHost] that only remembers what it was told.
class _RecordingMotionHost implements MotionHost {
  final List<bool> told = <bool>[];

  @override
  set systemDisablesAnimations(bool value) => told.add(value);
}

/// Boots a game with no store behind it.
Future<FlappyMiataGame> boot(WidgetTester tester, {int seed = 0}) async {
  final FlappyMiataGame game = FlappyMiataGame(
    courseSeed: seed,
    highScoreStore: InMemoryHighScoreStore(),
  );
  await tester.pumpWidget(GameWidget<FlappyMiataGame>(game: game));
  await tester.pump();
  await tester.pump();
  await tester.pump();
  return game;
}

/// Advances [game] by exactly [frames] fixed steps.
void advance(FlappyMiataGame game, int frames) {
  for (int i = 0; i < frames; i++) {
    game.update(frame);
  }
}

/// A proved survivable input sequence for [seed].
List<bool> witnessInputs({int seed = 0, int obstacles = 3}) {
  final ProofResult proof = FairnessProver()
      .prove(Course.fromSeed(seed, 0, obstacles), witness: true);
  if (!proof.survivable) throw StateError('no witness for seed $seed');
  return proof.witness!;
}

/// Drives a whole run and lets it end.
void driveToDeath(FlappyMiataGame game, List<bool> inputs) {
  for (int i = 0; i < inputs.length; i++) {
    if (inputs[i]) game.startRun();
    advance(game, 1);
  }
  advance(game, 800);
}

void main() {
  group('the setting resolves the way it says it does', () {
    test('all six cases, exhaustively', () {
      // Two booleans-worth of input and six answers, so there is no reason to
      // check a sample of them.
      expect(
          shouldReduceMotion(
              setting: MotionSetting.system,
              systemDisablesAnimations: false),
          isFalse);
      expect(
          shouldReduceMotion(
              setting: MotionSetting.system, systemDisablesAnimations: true),
          isTrue,
          reason: 'the platform asked for less motion and was ignored');
      expect(
          shouldReduceMotion(
              setting: MotionSetting.reduced,
              systemDisablesAnimations: false),
          isTrue,
          reason: 'the in-app override cannot turn it on');
      expect(
          shouldReduceMotion(
              setting: MotionSetting.reduced, systemDisablesAnimations: true),
          isTrue);
      expect(
          shouldReduceMotion(
              setting: MotionSetting.full, systemDisablesAnimations: false),
          isFalse);
      expect(
          shouldReduceMotion(
              setting: MotionSetting.full, systemDisablesAnimations: true),
          isFalse,
          reason: 'the in-app override cannot turn it off, which is the other '
              'half of what an override is for');
    });

    test('the cycle visits every setting and comes back', () {
      MotionSetting s = MotionSetting.system;
      final List<MotionSetting> seen = <MotionSetting>[s];
      for (int i = 0; i < MotionSetting.values.length; i++) {
        s = nextMotionSetting(s);
        seen.add(s);
      }
      expect(seen.first, seen.last, reason: 'the cycle does not close');
      expect(seen.toSet(), MotionSetting.values.toSet(),
          reason: 'a setting is unreachable from the control');
      // Reduced comes first, because somebody hunting for this control is
      // looking for "stop it".
      expect(nextMotionSetting(MotionSetting.system), MotionSetting.reduced);
    });

    test('the label says what will happen, not just which mode it is in', () {
      expect(
          motionSettingLabel(
              setting: MotionSetting.system,
              systemDisablesAnimations: false),
          'MOTION: AUTO (FULL)');
      expect(
          motionSettingLabel(
              setting: MotionSetting.system, systemDisablesAnimations: true),
          'MOTION: AUTO (REDUCED)',
          reason: 'on AUTO the label has to name the resolved state, or it '
              'answers a question nobody asked');
      expect(
          motionSettingLabel(
              setting: MotionSetting.reduced,
              systemDisablesAnimations: false),
          'MOTION: REDUCED');
      expect(
          motionSettingLabel(
              setting: MotionSetting.full, systemDisablesAnimations: true),
          'MOTION: FULL');
    });
  });

  group('the decorative clock', () {
    test('advances when motion is full and does not when it is reduced', () {
      final DecorClock clock = DecorClock();
      clock.advance(frame, reduced: false);
      expect(clock.phase, closeTo(frame, 1e-12));
      final double before = clock.phase;
      for (int i = 0; i < 600; i++) {
        clock.advance(frame, reduced: true);
      }
      expect(clock.phase, before,
          reason: 'ten seconds of decoration were banked while it was off');
    });

    test('the seconds spent reduced are not banked for later', () {
      // THE SUBTLE ONE. Banking the time and simply not drawing it would look
      // identical until the player turned the setting back off, at which point
      // the hills would jump by however long they had it on — a large, sudden
      // movement produced by the control whose whole job is to prevent large,
      // sudden movements.
      final DecorClock paused = DecorClock();
      final DecorClock running = DecorClock();
      for (int i = 0; i < 300; i++) {
        paused.advance(frame, reduced: true);
        running.advance(frame, reduced: false);
      }
      paused.advance(frame, reduced: false);
      running.advance(frame, reduced: false);
      expect(paused.phase, closeTo(frame, 1e-12));
      expect(running.phase, greaterThan(5.0));
    });

    test('a nonsense dt cannot poison it', () {
      final DecorClock clock = DecorClock();
      clock.advance(double.nan, reduced: false);
      clock.advance(double.infinity, reduced: false);
      clock.advance(-1.0, reduced: false);
      expect(clock.phase, 0.0);
      expect(clock.phase.isFinite, isTrue);
    });

    test('the parallax offset wraps and never leaves [0, 1)', () {
      for (double phase = 0.0; phase < 400.0; phase += 0.37) {
        for (final double speed in <double>[
          cloudDriftPerSecond,
          hillDriftPerSecond,
        ]) {
          final double o = parallaxOffset(phase, speed);
          expect(o, greaterThanOrEqualTo(0.0), reason: '$phase at $speed');
          expect(o, lessThan(1.0), reason: '$phase at $speed');
        }
      }
      expect(parallaxOffset(0.0, hillDriftPerSecond), 0.0);
      expect(parallaxOffset(double.nan, hillDriftPerSecond), 0.0);
    });

    test('the clouds really are slower than the hills', () {
      // Parallax IS the speed ratio. If the two were equal there would be no
      // depth to reduce, and this test file would be about nothing.
      expect(cloudDriftPerSecond, lessThan(hillDriftPerSecond));
      // And both are far slower than the world, or the backdrop would read as
      // part of the course.
      expect(hillDriftPerSecond, lessThan(GameModel.scrollSpeed / 4));
    });

    test('a stopped offset really is a stopped picture', () {
      // The other side of the clock test, at the level the renderer reads: two
      // phases that differ have to give different offsets, or "the clock
      // stopped" would not imply "the picture stopped".
      expect(parallaxOffset(1.0, hillDriftPerSecond),
          isNot(parallaxOffset(2.0, hillDriftPerSecond)));
      expect(parallaxOffset(3.0, hillDriftPerSecond),
          parallaxOffset(3.0, hillDriftPerSecond));
    });
  });

  group('the platform switch is the default', () {
    testWidgets('the bridge reports what MediaQuery says', (
      WidgetTester tester,
    ) async {
      final _RecordingMotionHost host = _RecordingMotionHost();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: SystemMotionBridge(host: host, child: const SizedBox()),
        ),
      );
      expect(host.told, isNotEmpty, reason: 'the bridge never told the host '
          'anything, so the platform setting is not reaching the game');
      expect(host.told.last, isTrue);
    });

    testWidgets('and it notices when the platform changes its mind', (
      WidgetTester tester,
    ) async {
      // Not a one-off read. A player can flip the switch in the system settings
      // while the app is open, and `didChangeDependencies` is what fires when
      // they do.
      final _RecordingMotionHost host = _RecordingMotionHost();
      Future<void> pumpWith(bool disable) => tester.pumpWidget(
            MediaQuery(
              data: MediaQueryData(disableAnimations: disable),
              child: SystemMotionBridge(host: host, child: const SizedBox()),
            ),
          );
      await pumpWith(false);
      expect(host.told.last, isFalse);
      await pumpWith(true);
      expect(host.told.last, isTrue);
      await pumpWith(false);
      expect(host.told.last, isFalse);
    });

    testWidgets('a game under the bridge follows the platform', (
      WidgetTester tester,
    ) async {
      final FlappyMiataGame game = FlappyMiataGame(
        courseSeed: 0,
        highScoreStore: InMemoryHighScoreStore(),
      );
      expect(game.reduceMotion, isFalse,
          reason: 'a game with no platform under it must not assume one');

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: SystemMotionBridge(
            host: game,
            child: GameWidget<FlappyMiataGame>(game: game),
          ),
        ),
      );
      await tester.pump();
      expect(game.motionSetting, MotionSetting.system,
          reason: 'the default has to be to follow the platform');
      expect(game.reduceMotion, isTrue);
    });
  });

  group('what reduced motion actually stops', () {
    testWidgets('the decoration freezes and the run does not', (
      WidgetTester tester,
    ) async {
      // Driven by a PROVED survivable input sequence, in two halves with the
      // setting flipped in between. A hand-rolled tap pattern would have the
      // car crash somewhere in the middle for reasons that say nothing about
      // this setting, and the assertion below needs the run to still be live.
      final List<bool> inputs = witnessInputs();
      final int half = inputs.length ~/ 2;

      final FlappyMiataGame game = await boot(tester);
      for (int i = 0; i < half; i++) {
        if (inputs[i]) game.startRun();
        advance(game, 1);
      }
      expect(game.model.state, RunState.playing);
      expect(game.decorPhase, greaterThan(0.0),
          reason: 'the parallax was never running, so stopping it below would '
              'prove nothing');

      // Force it off from inside the app: system -> reduced.
      game.cycleMotion();
      expect(game.motionSetting, MotionSetting.reduced);
      expect(game.reduceMotion, isTrue);

      final double frozen = game.decorPhase;
      final GameModel before = game.model;
      for (int i = half; i < inputs.length; i++) {
        if (inputs[i]) game.startRun();
        advance(game, 1);
      }

      expect(game.decorPhase, frozen, reason: 'the parallax kept moving');
      expect(game.model, isNot(before),
          reason: 'the GAME stopped too, which is not what was asked for');
      expect(game.model.state, RunState.playing,
          reason: 'the run ended during the stretch this was measured over, '
              'so it says nothing about a live game');
      expect(game.score, greaterThan(0),
          reason: 'the world did not actually go anywhere');
    });

    testWidgets('and it starts again when the player turns it back on', (
      WidgetTester tester,
    ) async {
      final FlappyMiataGame game = await boot(tester);
      game.startRun();
      game.cycleMotion();
      advance(game, 60);
      final double frozen = game.decorPhase;

      // reduced -> full.
      game.cycleMotion();
      expect(game.reduceMotion, isFalse);
      advance(game, 60);
      expect(game.decorPhase, greaterThan(frozen));
    });

    testWidgets('the pixels really move, and really stop', (
      WidgetTester tester,
    ) async {
      // ======================================================================
      // THE GAP EVERY OTHER TEST IN THIS FILE LEAVES OPEN.
      //
      // The tests above check a clock and a wrapping function. All of them
      // would still pass if `_BackdropLayer.render` never read the clock at
      // all — the switch would work perfectly and the hills would sit still
      // for everybody, which is a reduced-motion mode that reduces nothing
      // because there was never any motion to reduce.
      //
      // So this renders the game to actual pixels and compares them. It works
      // because a run that has not started yet does not advance: `tick`
      // returns the receiver while the state is `ready`, so the model is
      // provably identical between the two frames and the ONLY thing that can
      // differ is the decoration.
      // ======================================================================
      final FlappyMiataGame game = await boot(tester);
      expect(game.model.state, RunState.ready);

      Future<Uint8List> shot() async {
        final Uint8List? bytes = await tester.runAsync<Uint8List>(() async {
          final ui.PictureRecorder recorder = ui.PictureRecorder();
          game.renderTree(Canvas(recorder));
          final ui.Image image = await recorder.endRecording().toImage(
                game.size.x.round(),
                game.size.y.round(),
              );
          final ByteData? data =
              await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          image.dispose();
          return data!.buffer.asUint8List();
        });
        expect(bytes, isNotNull, reason: 'the game could not be rendered');
        return bytes!;
      }

      final GameModel still = game.model;
      final Uint8List before = await shot();
      advance(game, 180);
      expect(game.model, still,
          reason: 'the run advanced, so a difference in the pixels below '
              'would not be about the backdrop');
      expect(game.decorPhase, greaterThan(0.0));
      final Uint8List after = await shot();

      expect(after, isNot(before),
          reason: 'three seconds passed with motion at full and the game drew '
              'exactly the same pixels — the parallax is not wired to the '
              'clock, so the switch below is switching nothing off');

      // And with motion reduced, three more seconds change nothing at all.
      game.cycleMotion();
      expect(game.reduceMotion, isTrue);
      final Uint8List frozenA = await shot();
      advance(game, 180);
      expect(game.model, still);
      final Uint8List frozenB = await shot();
      expect(frozenB, frozenA,
          reason: 'the backdrop is still moving with motion reduced');
    });

    testWidgets('pausing stops the decoration too', (
      WidgetTester tester,
    ) async {
      // A stopped world whose hills kept sliding would be a paused game that
      // still looked like it was moving.
      final FlappyMiataGame game = await boot(tester);
      game.startRun();
      advance(game, 30);
      game.pauseRun();
      final double frozen = game.decorPhase;
      advance(game, 120);
      expect(game.decorPhase, frozen);
    });
  });

  group('IT IS NOT AN EASY MODE', () {
    testWidgets('the same taps give the same run with motion reduced', (
      WidgetTester tester,
    ) async {
      // THE CENTRAL ASSERTION OF THIS FILE. Two games, the same course, the
      // same recorded inputs, one with the decoration running and one with it
      // stopped — and the two runs have to be the same run.
      final List<bool> inputs = witnessInputs();

      final FlappyMiataGame full = await boot(tester);
      expect(full.reduceMotion, isFalse);
      driveToDeath(full, inputs);

      final FlappyMiataGame reduced = await boot(tester);
      reduced.cycleMotion();
      expect(reduced.reduceMotion, isTrue);
      driveToDeath(reduced, inputs);

      expect(reduced.model, full.model,
          reason: 'reducing motion changed the run');
      expect(reduced.score, full.score);
      expect(reduced.riskScore, full.riskScore);
      expect(reduced.model.state, RunState.dead);

      // Non-vacuous: both runs actually went somewhere, so "identical" is not
      // "identically nothing".
      expect(full.score, greaterThan(0));

      // And the decoration really was in different states throughout, so the
      // equality above is a statement about two genuinely different renderings
      // of the same run.
      expect(reduced.decorPhase, lessThan(full.decorPhase));
    });

    testWidgets('the platform switch cannot change a run either', (
      WidgetTester tester,
    ) async {
      // The same claim through the OTHER route into the setting. An app that
      // was careful about its own toggle and careless about the accessibility
      // switch would pass the test above and still ship an easy mode to exactly
      // the players who did not choose one.
      final List<bool> inputs = witnessInputs();

      final FlappyMiataGame plain = FlappyMiataGame(
        courseSeed: 0,
        highScoreStore: InMemoryHighScoreStore(),
      );
      await tester.pumpWidget(GameWidget<FlappyMiataGame>(game: plain));
      await tester.pump();
      await tester.pump();
      driveToDeath(plain, inputs);

      final FlappyMiataGame bridged = FlappyMiataGame(
        courseSeed: 0,
        highScoreStore: InMemoryHighScoreStore(),
      );
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: SystemMotionBridge(
            host: bridged,
            child: GameWidget<FlappyMiataGame>(game: bridged),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(bridged.reduceMotion, isTrue);
      driveToDeath(bridged, inputs);

      expect(bridged.model, plain.model);
      expect(bridged.score, plain.score);
      expect(bridged.riskScore, plain.riskScore);
      expect(plain.score, greaterThan(0));
    });

    testWidgets('the game is still fully playable with motion reduced', (
      WidgetTester tester,
    ) async {
      // "Playable" said as behaviour rather than as a claim: from the start
      // line, a tap starts a run, the world moves, obstacles arrive, the score
      // goes up, pausing and resuming work, and a crash ends it.
      final FlappyMiataGame game = await boot(tester);
      game.cycleMotion();
      expect(game.reduceMotion, isTrue);

      expect(game.model.state, RunState.ready);
      game.startRun();
      advance(game, 1);
      expect(game.model.state, RunState.playing);

      driveToDeath(game, witnessInputs());
      expect(game.score, greaterThan(0),
          reason: 'a run played with motion reduced could not score');
      expect(game.model.state, RunState.dead);

      game.restartRun();
      expect(game.model.state, RunState.ready);
      game.startRun();
      advance(game, 30);
      game.pauseRun();
      expect(game.paused, isTrue);
      game.resumeRun();
      expect(game.paused, isFalse);
      advance(game, 30);
      expect(game.model.obstacles, isNotEmpty);
    });
  });

  group('the control is on the screens that can afford it', () {
    testWidgets('the start and paused screens offer it, and it calls through', (
      WidgetTester tester,
    ) async {
      for (final Widget screen in <Widget>[
        StartScreen(host: _Host()),
        PausedScreen(host: _Host()),
      ]) {
        final _Host host = (screen is StartScreen
            ? screen.host
            : (screen as PausedScreen).host) as _Host;
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: MediaQuery(data: const MediaQueryData(), child: screen),
          ),
        );
        expect(find.text('MOTION: AUTO (FULL)'), findsOneWidget);
        await tester.tap(find.text('MOTION: AUTO (FULL)'));
        expect(host.calls, <String>['motion'],
            reason: 'the tap fell through to the scaffold instead of reaching '
                'the control');
      }
    });

    testWidgets('it is NOT offered during play', (WidgetTester tester) async {
      // Same reasoning as the assist toggle: the label has to be read to be
      // useful, and reading it costs the run.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: PauseButton(host: _Host()),
          ),
        ),
      );
      expect(find.byType(MotionToggle), findsNothing);
    });

    testWidgets('the label follows the platform on AUTO', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: StartScreen(host: _Host(systemDisablesAnimations: true)),
          ),
        ),
      );
      expect(find.text('MOTION: AUTO (REDUCED)'), findsOneWidget);
    });

    testWidgets('an in-app override says so instead of blaming the platform', (
      WidgetTester tester,
    ) async {
      // The setting is FULL while the platform is asking for reduced motion —
      // the case where the two disagree, which is the whole reason there is an
      // override. The label must report the setting that is actually in force.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: StartScreen(
              host: _Host(
                motionSetting: MotionSetting.full,
                systemDisablesAnimations: true,
              ),
            ),
          ),
        ),
      );
      expect(find.text('MOTION: FULL'), findsOneWidget);
      expect(find.textContaining('AUTO'), findsNothing);
    });
  });
}
