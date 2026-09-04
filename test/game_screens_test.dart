/// The screens, and the two things about them that are behaviour rather than
/// appearance: which one is up, and what pausing actually does.
///
/// ============================================================================
/// WHAT A TEST CAN AND CANNOT SEE HERE — READ THIS BEFORE TRUSTING THE FILE
/// ============================================================================
///
/// NO EMULATOR OR DEVICE WAS AVAILABLE while these screens were written. Nothing
/// below has run on hardware. What is checked is that the right widget is in the
/// tree, that its labels say the right numbers, and that its buttons call the
/// right thing. What is NOT checked, and cannot be from here: whether any of it
/// is legible on a phone, whether the pause button is big enough to hit with a
/// thumb, whether the card fits on a small screen, or whether the scrim leaves
/// the game readable behind it.
///
/// The pause tests are a different matter and are exact. Pausing is not a
/// picture — it is "the model does not advance", and the model is immutable and
/// value-compared, so "did not advance" is a single assertion and "resumed from
/// the same state" is another.
library;

import 'dart:async';

import 'package:flame/game.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/game/game_model.dart';
import 'package:flappymiata/game/replay.dart';
import 'package:flappymiata/game/run_code.dart';
import 'package:flappymiata/main.dart';
import 'package:flappymiata/ui/game_screens.dart';
import 'package:flappymiata/ui/high_score_store.dart';
import 'package:flappymiata/ui/motion.dart';

import '../tool/fairness.dart';

/// A stand-in for the game, so the screens can be driven with no game loop.
///
/// This is the payoff for `GameScreenHost` being an interface: every widget in
/// `lib/ui/game_screens.dart` can be put on screen in any state at all —
/// including states that would take a real run several seconds to reach — and
/// the buttons can be checked by what they CALL rather than by what happens
/// afterwards.
class FakeHost implements GameScreenHost {
  /// A screen may listen to this; nothing in these tests ever fires it, because
  /// each one builds the screen it wants directly rather than waiting for the
  /// game to change under it.
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  @override
  Listenable get revision => _revision;

  @override
  int score;

  @override
  int riskScore;

  @override
  int bestScore;

  @override
  bool hasBestScore;

  /// Defaults to FALSE, and that default is doing work. `NEW BEST` is the
  /// exceptional case, so a host built without saying anything about it must
  /// not claim one — otherwise every screen test in this file would be
  /// asserting against a card that congratulates the player unconditionally.
  @override
  bool isNewBest;

  @override
  bool paused;

  @override
  bool assistEnabled;

  /// Defaults to TRUE, because that is the default the real game ships with —
  /// see `FlappyMiataGame._ghostVisible`. A fake that started anywhere else
  /// would let a screen test pass while the app opened on a setting nobody
  /// chose, which is the same argument [motionSetting] carries below.
  @override
  bool ghostEnabled;

  /// Defaults to [MotionSetting.system], because that is the default the real
  /// game ships with — a fake that started anywhere else would let a screen
  /// test pass while the app opened on a setting nobody chose.
  @override
  MotionSetting motionSetting;

  @override
  bool systemDisablesAnimations;

  /// Every verb the screens invoked, in order.
  final List<String> calls = <String>[];

  FakeHost({
    this.score = 0,
    this.riskScore = 0,
    this.bestScore = 0,
    this.hasBestScore = false,
    this.isNewBest = false,
    this.paused = false,
    this.assistEnabled = false,
    this.ghostEnabled = true,
    this.motionSetting = MotionSetting.system,
    this.systemDisablesAnimations = false,
  });

  @override
  void toggleAssist() => calls.add('assist');

  @override
  void toggleGhost() => calls.add('ghost');

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

/// Puts one screen on the tester, with the ancestors a bare widget needs.
Future<void> showScreen(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(data: const MediaQueryData(), child: screen),
    ),
  );
}

/// One frame at 60fps.
const double frame = 1.0 / 60.0;

/// A run on [seed] that really scores, built from a proved witness.
///
/// The prover is used rather than a bot for the same reason
/// `test/high_score_store_test.dart` uses it: a fixture that scored nothing
/// would make "the best score came back" pass without a best score existing.
Replay provedRun({int seed = 0, int obstacles = 3}) {
  final ProofResult proof = FairnessProver()
      .prove(Course.fromSeed(seed, 0, obstacles), witness: true);
  if (!proof.survivable) {
    throw StateError('no witness for seed $seed');
  }
  final List<bool> inputs = proof.witness!;
  return Replay(
    seed: seed,
    tapFrames: <int>[
      for (int i = 0; i < inputs.length; i++)
        if (inputs[i]) i,
    ],
    frames: inputs.length,
  );
}

/// A store that already holds [run], as if the app had been played before.
InMemoryHighScoreStore storeHolding(Replay run) => InMemoryHighScoreStore(
  BestRun(score: replayFinalModel(run).score, code: encodeRunCode(run)),
);

/// A real run that scores NOTHING: one tap, then gravity.
///
/// Needed as a fixture rather than as a hand-made string because a stored record
/// is re-executed before it is believed — see `lib/ui/high_score_store.dart` —
/// so "the device already holds a best of zero" has to be an actual run that
/// actually scores zero. The car leaves the bottom of the playfield after about
/// 77 frames and the first obstacle does not reach it for 115, so this is a
/// genuine zero and not a truncation.
Replay zeroScoringRun({int seed = 0}) =>
    Replay(seed: seed, tapFrames: const <int>[0], frames: 200);

/// An [InMemoryHighScoreStore] that counts how often it was written to.
///
/// WHY A COUNTER AND NOT A COMPARISON: the question is whether a run that ties
/// the record is written to storage, and a re-save of the SAME run produces a
/// byte-identical record — so comparing what is in the store before and after
/// cannot tell "it was not saved" from "it was saved again". The write itself is
/// the thing being asserted about, so the write is what gets counted.
class CountingHighScoreStore implements HighScoreStore {
  final InMemoryHighScoreStore _inner;

  /// How many times [save] has been called.
  int saves = 0;

  CountingHighScoreStore([BestRun? seed])
    : _inner = InMemoryHighScoreStore(seed);

  /// What is held right now.
  BestRun? get current => _inner.current;

  @override
  Future<BestRun?> load() => _inner.load();

  @override
  Future<void> save(BestRun best) {
    saves++;
    return _inner.save(best);
  }
}

/// How many further frames [driveToDeath] coasts for once the inputs run out.
///
/// A witness ends the moment the course is cleared, with the car still alive —
/// and the game only files a best score when a run FINISHES. So the run has to
/// be allowed to end, which with no further taps takes about a second.
const int driveTail = 800;

/// Drives [game] with a recorded input sequence and then lets the run end.
///
/// `startRun` is the game's own "a tap happened" verb — it queues the tap onto
/// the next fixed frame exactly as a touch on the playfield does — so this
/// really is the run being played rather than a model being poked.
void driveToDeath(FlappyMiataGame game, List<bool> inputs) {
  for (int i = 0; i < inputs.length; i++) {
    if (inputs[i]) game.startRun();
    advance(game, 1);
  }
  advance(game, driveTail);
}

/// The same inputs as a [Replay] carried out to the same end, so the score
/// [driveToDeath] will produce can be worked out in advance.
///
/// Both sides step the identical model at the identical timestep, so this is not
/// a prediction — it is the same computation, done twice.
Replay recordedFrom(List<bool> inputs, {int seed = 0}) => Replay(
  seed: seed,
  tapFrames: <int>[
    for (int i = 0; i < inputs.length; i++)
      if (inputs[i]) i,
  ],
  frames: inputs.length + driveTail,
);

/// A witness for the first [obstacles] obstacles of [seed], as raw inputs.
List<bool> witnessInputs({int seed = 0, int obstacles = 3}) {
  final ProofResult proof = FairnessProver()
      .prove(Course.fromSeed(seed, 0, obstacles), witness: true);
  if (!proof.survivable) throw StateError('no witness for seed $seed');
  return proof.witness!;
}

/// Boots a game and lets its `onLoad` finish.
Future<FlappyMiataGame> boot(
  WidgetTester tester, {
  int seed = 0,
  HighScoreStore? store,
}) async {
  final FlappyMiataGame game = FlappyMiataGame(
    courseSeed: seed,
    highScoreStore: store ?? InMemoryHighScoreStore(),
  );
  await tester.pumpWidget(GameWidget<FlappyMiataGame>(game: game));
  // Three pumps: mount, let `onLoad` settle, and let the asynchronous best-score
  // load land. None of them advances the test clock, so no game time passes and
  // the run is still exactly where it started.
  await tester.pump();
  await tester.pump();
  await tester.pump();
  return game;
}

/// Advances the game by exactly [frames] fixed steps.
///
/// `game.update` is called directly rather than pumping the tester, because the
/// accumulator turns a real duration into a WHOLE number of steps and the
/// leftover carry makes "pump 16ms" mean "one step, usually". Handing it exactly
/// one frame's worth leaves a carry of exactly zero, so the step count is a fact
/// rather than an expectation — which is what lets the pause tests below compare
/// whole models instead of comparing them loosely.
void advance(FlappyMiataGame game, int frames) {
  for (int i = 0; i < frames; i++) {
    game.update(frame);
  }
}

void main() {
  group('overlaysFor — exactly one screen, always', () {
    test('every state maps to one overlay and they are all registered', () {
      // Exhaustive over both arguments. The failure this rules out is not a
      // wrong screen, which somebody would notice — it is TWO screens stacked,
      // or none at all, which on a device reads as a frozen game.
      for (final RunState state in RunState.values) {
        for (final bool paused in <bool>[false, true]) {
          final Set<String> got = overlaysFor(state: state, paused: paused);
          expect(got, hasLength(1),
              reason: 'state $state, paused $paused gave $got');
          expect(gameScreenOverlays, contains(got.single),
              reason: '${got.single} is not a registered overlay, so nothing '
                  'would draw it');
        }
      }
    });

    test('the screens are the ones the design says', () {
      expect(overlaysFor(state: RunState.ready, paused: false),
          <String>{startOverlay});
      expect(overlaysFor(state: RunState.playing, paused: false),
          <String>{pauseButtonOverlay});
      expect(overlaysFor(state: RunState.dead, paused: false),
          <String>{gameOverOverlay});
    });

    test('paused wins over every run state', () {
      // Pausing is tracked beside the model rather than inside it — `RunState`
      // has three values on purpose — so the two can disagree, and this is the
      // rule for what happens when they do.
      for (final RunState state in RunState.values) {
        expect(overlaysFor(state: state, paused: true),
            <String>{pausedOverlay}, reason: 'state $state');
      }
    });
  });

  group('the screens say the right things and call the right things', () {
    testWidgets('the start screen offers a drive and reports a best', (
      WidgetTester tester,
    ) async {
      final FakeHost host = FakeHost(bestScore: 17, hasBestScore: true);
      await showScreen(tester, StartScreen(host: host));

      expect(find.text('FLAPPY MIATA'), findsOneWidget);
      expect(find.text('BEST'), findsOneWidget);
      expect(find.text('17'), findsOneWidget);

      await tester.tap(find.text('TAP TO DRIVE'));
      expect(host.calls, <String>['start']);
    });

    testWidgets('a first-time start screen shows no best at all', (
      WidgetTester tester,
    ) async {
      // "BEST 0" and "no best yet" are different claims, and a fresh install
      // must make the second one. This is why the host carries `hasBestScore`
      // rather than letting 0 stand in for "none".
      await showScreen(tester, StartScreen(host: FakeHost()));
      expect(find.text('BEST'), findsNothing);
    });

    testWidgets('a tap anywhere on the start screen drives', (
      WidgetTester tester,
    ) async {
      // The behaviour the game has always had, kept: the whole surface is the
      // button. The card is a label, not a gate.
      final FakeHost host = FakeHost();
      await showScreen(tester, StartScreen(host: host));
      await tester.tapAt(const Offset(20, 20));
      expect(host.calls, <String>['start']);
    });

    testWidgets('the paused screen resumes and restarts', (
      WidgetTester tester,
    ) async {
      final FakeHost host = FakeHost(score: 9, paused: true);
      await showScreen(tester, PausedScreen(host: host));

      expect(find.text('PAUSED'), findsOneWidget);
      expect(find.text('9'), findsOneWidget);

      await tester.tap(find.text('RESUME'));
      await tester.tap(find.text('RESTART'));
      expect(host.calls, <String>['resume', 'restart']);
    });

    testWidgets('a tap on the paused screen does NOT resume', (
      WidgetTester tester,
    ) async {
      // The one place tap-anywhere would be wrong. A player who deliberately
      // stopped the game must not lose the run to a stray touch, and the tap
      // must not fall through to the game underneath and be read as a flap
      // either — so the scrim swallows it and does nothing.
      final FakeHost host = FakeHost(score: 4, paused: true);
      await showScreen(tester, PausedScreen(host: host));
      await tester.tapAt(const Offset(20, 20));
      expect(host.calls, isEmpty);
    });

    testWidgets('the game over screen reports the score and plays again', (
      WidgetTester tester,
    ) async {
      final FakeHost host =
          FakeHost(score: 5, bestScore: 12, hasBestScore: true);
      await showScreen(tester, GameOverScreen(host: host));

      expect(find.text('RUN OVER'), findsOneWidget);
      expect(find.text('SCORE'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
      expect(find.text('BEST'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.text('NEW BEST'), findsNothing,
          reason: '5 did not beat 12');

      await tester.tap(find.text('PLAY AGAIN'));
      expect(host.calls, <String>['restart']);
    });

    testWidgets('a run that set the record says so', (
      WidgetTester tester,
    ) async {
      final FakeHost host = FakeHost(
        score: 12,
        bestScore: 12,
        hasBestScore: true,
        isNewBest: true,
      );
      await showScreen(tester, GameOverScreen(host: host));
      expect(find.text('NEW BEST'), findsOneWidget);
    });

    // ------------------------------------------------------------------------
    // The bug this pair was written for: the card congratulated a run that
    // scored NOTHING.
    //
    // The screen used to work `NEW BEST` out for itself, as
    // `hasBestScore && score >= bestScore`, on the argument that a run only ever
    // ties or beats the record at the moment it ends. A first run that scores
    // zero records a best of zero, so the card read 0 >= 0 and said NEW BEST for
    // a car that never passed a pipe. The same comparison also congratulated any
    // run that merely TIED an older record.
    //
    // Both cases are the same defect and both are below, because a fix that only
    // special-cased zero would leave the second one shipped.
    // ------------------------------------------------------------------------

    testWidgets('a run that scored nothing is not a NEW BEST', (
      WidgetTester tester,
    ) async {
      // Exactly the state after a first-ever run that died before the first
      // pipe: a best of 0 has been recorded, and nothing was beaten to get it.
      final FakeHost host = FakeHost(
        score: 0,
        bestScore: 0,
        hasBestScore: true,
        isNewBest: false,
      );
      await showScreen(tester, GameOverScreen(host: host));

      expect(find.text('NEW BEST'), findsNothing,
          reason: 'scoring nothing beat nothing');
      // Non-vacuous: the card really is up and really is reporting that run, so
      // the absence above is about the banner and not about an empty screen.
      expect(find.text('RUN OVER'), findsOneWidget);
      expect(find.text('BEST'), findsOneWidget);
    });

    testWidgets('a run that only ties the record is not a NEW BEST', (
      WidgetTester tester,
    ) async {
      final FakeHost host = FakeHost(
        score: 7,
        bestScore: 7,
        hasBestScore: true,
        isNewBest: false,
      );
      await showScreen(tester, GameOverScreen(host: host));

      expect(find.text('NEW BEST'), findsNothing,
          reason: 'equalling a record is not setting one');
      expect(find.text('7'), findsWidgets);
    });

    testWidgets('the assist toggle states what it is, not what it does', (
      WidgetTester tester,
    ) async {
      // The label reads as the CURRENT state, so a glance answers "is it on?" —
      // which is the question somebody who has just been shown an unexpected
      // line across the screen is asking.
      final FakeHost off = FakeHost();
      await showScreen(tester, StartScreen(host: off));
      expect(find.text('ASSIST: OFF'), findsOneWidget);
      await tester.tap(find.text('ASSIST: OFF'));
      expect(off.calls, <String>['assist'],
          reason: 'the toggle did not reach the game — or the tap fell through '
              'to the scaffold and started a run instead');

      final FakeHost on = FakeHost(assistEnabled: true);
      await showScreen(tester, StartScreen(host: on));
      expect(find.text('ASSIST: ON'), findsOneWidget);
      expect(find.text('ASSIST: OFF'), findsNothing);
    });

    testWidgets('the paused screen reports the risk score and offers assist', (
      WidgetTester tester,
    ) async {
      final FakeHost host = FakeHost(score: 9, riskScore: 23, paused: true);
      await showScreen(tester, PausedScreen(host: host));
      expect(find.text('RISK'), findsOneWidget);
      expect(find.text('23'), findsOneWidget);
      expect(find.text('ASSIST: OFF'), findsOneWidget);
    });

    testWidgets('the ghost toggle states what it is, on both stopped screens', (
      WidgetTester tester,
    ) async {
      // Same shape as the assist toggle above, and it is a separate test rather
      // than an extra line in that one because it is a separate claim: the
      // control has to exist on BOTH screens the world is stopped on. The
      // paused screen is the one that matters most here — it is the only place
      // a player who has just been confused by the ghost mid-run can reach the
      // switch without throwing the run away.
      final FakeHost on = FakeHost();
      await showScreen(tester, StartScreen(host: on));
      expect(find.text('GHOST: ON'), findsOneWidget,
          reason: 'the ghost ships on, so a fresh screen must say so');
      expect(find.text('GHOST: OFF'), findsNothing);
      await tester.tap(find.text('GHOST: ON'));
      expect(on.calls, <String>['ghost'],
          reason: 'the toggle did not reach the game — or the tap fell through '
              'to the scaffold and started a run instead');

      final FakeHost off =
          FakeHost(score: 9, paused: true, ghostEnabled: false);
      await showScreen(tester, PausedScreen(host: off));
      expect(find.text('GHOST: OFF'), findsOneWidget);
      expect(find.text('GHOST: ON'), findsNothing);
      await tester.tap(find.text('GHOST: OFF'));
      expect(off.calls, <String>['ghost']);
    });

    testWidgets('every display setting is on both stopped screens', (
      WidgetTester tester,
    ) async {
      // The three controls are three separate widgets added in two separate
      // places, so "somebody added the fourth one to the start screen only" is
      // a real and invisible failure. Named here as one list, once.
      const List<String> controls = <String>[
        'ASSIST: OFF',
        'GHOST: ON',
        'MOTION: AUTO (FULL)',
      ];
      for (final Widget screen in <Widget>[
        StartScreen(host: FakeHost()),
        PausedScreen(host: FakeHost(paused: true)),
      ]) {
        await showScreen(tester, screen);
        for (final String label in controls) {
          expect(find.text(label), findsOneWidget,
              reason: '$label is missing from ${screen.runtimeType}');
        }
      }
    });

    testWidgets('the game over card reports risk beside the score, not in it', (
      WidgetTester tester,
    ) async {
      // Two numbers, never a total. `score` is what every stored record and
      // every run code is verified against; adding the risk into it would
      // invalidate all of them.
      // The best is 33 rather than 20 on purpose: 20 is the SUM of the other
      // two, and a card showing it would be indistinguishable from a card
      // showing the best if the two numbers were the same.
      final FakeHost host =
          FakeHost(score: 6, riskScore: 14, bestScore: 33, hasBestScore: true);
      await showScreen(tester, GameOverScreen(host: host));
      expect(find.text('SCORE'), findsOneWidget);
      expect(find.text('6'), findsOneWidget);
      expect(find.text('RISK'), findsOneWidget);
      expect(find.text('14'), findsOneWidget);
      expect(find.text('33'), findsOneWidget, reason: 'the best is still shown');
      expect(find.text('${6 + 14}'), findsNothing,
          reason: 'the two numbers were added together somewhere');
    });

    testWidgets('a tap anywhere on the game over screen restarts', (
      WidgetTester tester,
    ) async {
      final FakeHost host = FakeHost(score: 2);
      await showScreen(tester, GameOverScreen(host: host));
      await tester.tapAt(const Offset(20, 20));
      expect(host.calls, <String>['restart']);
    });

    testWidgets('the pause button pauses, and only covers its own corner', (
      WidgetTester tester,
    ) async {
      final FakeHost host = FakeHost(score: 3);
      await showScreen(tester, PauseButton(host: host));

      await tester.tap(find.text('‖'));
      expect(host.calls, <String>['pause']);

      // The important half: the rest of the screen is NOT covered. A pause
      // control that swallowed the playfield would make the game unplayable
      // while looking completely correct in a screenshot — every tap meant as a
      // flap would land on an invisible layer instead.
      host.calls.clear();
      final Rect whole = tester.getRect(find.byType(PauseButton));
      await tester.tapAt(whole.center);
      expect(host.calls, isEmpty,
          reason: 'a tap in the middle of the playfield hit the pause layer');

      // And the part that IS hit-testable is a corner, not the screen.
      final Rect button = tester.getRect(find.byType(GestureDetector));
      expect(button.width, lessThan(120));
      expect(button.height, lessThan(120));
      expect(whole.width, greaterThan(button.width * 2));
    });
  });

  group('pause actually pauses', () {
    testWidgets('the model does not advance while paused', (
      WidgetTester tester,
    ) async {
      final FlappyMiataGame game = await boot(tester);
      game.startRun();
      advance(game, 40);

      final GameModel before = game.model;
      expect(before.state, RunState.playing);
      expect(before.obstacles, isNotEmpty,
          reason: 'nothing on the playfield means nothing could have moved');

      game.pauseRun();
      expect(game.paused, isTrue);

      // Three hundred frames — five seconds of wall clock — during which the
      // world must not move by one lattice cell.
      advance(game, 300);
      expect(game.model, before,
          reason: 'the model advanced while the game was paused');
    });

    testWidgets('resuming continues from the same state rather than '
        'restarting', (WidgetTester tester) async {
      final FlappyMiataGame game = await boot(tester);
      game.startRun();
      advance(game, 40);

      final GameModel before = game.model;
      game.pauseRun();
      advance(game, 300);
      game.resumeRun();
      expect(game.paused, isFalse);

      advance(game, 1);

      // THE EXACT ASSERTION, and it is worth saying what it rules out. It fails
      // if the run restarted (the model would be `ready` at startY); it fails if
      // resuming rebuilt the state from anything; and it fails if the five
      // seconds spent paused had been BANKED, because then this single frame
      // would have spent several steps of catch-up and landed somewhere else
      // entirely. One frame of physics from exactly where it stopped.
      expect(game.model, before.tick(frame));
    });

    testWidgets('pausing is refused when there is no live run', (
      WidgetTester tester,
    ) async {
      final FlappyMiataGame game = await boot(tester);

      // On the start line: there is nothing to stop.
      expect(game.model.state, RunState.ready);
      game.pauseRun();
      expect(game.paused, isFalse);

      // And after the crash: a paused game-over screen would be a screen with
      // nothing behind it to resume.
      game.startRun();
      advance(game, 400);
      expect(game.model.state, RunState.dead);
      game.pauseRun();
      expect(game.paused, isFalse);
    });

    testWidgets('a restart from the paused screen unpauses', (
      WidgetTester tester,
    ) async {
      final FlappyMiataGame game = await boot(tester);
      game.startRun();
      advance(game, 40);
      game.pauseRun();

      game.restartRun();
      expect(game.paused, isFalse);
      expect(game.model.state, RunState.ready);
      expect(game.model.score, 0);
      expect(game.model.obstacles, isEmpty);

      // And it really is running again, not merely reset.
      game.startRun();
      advance(game, 10);
      expect(game.model.state, RunState.playing);
    });

    testWidgets('the right screen is on the tree for each state', (
      WidgetTester tester,
    ) async {
      final FlappyMiataGame game = await boot(tester);
      expect(find.byType(StartScreen), findsOneWidget);

      game.startRun();
      advance(game, 20);
      await tester.pump();
      expect(find.byType(StartScreen), findsNothing);
      expect(find.byType(PauseButton), findsOneWidget);

      game.pauseRun();
      await tester.pump();
      expect(find.byType(PausedScreen), findsOneWidget);
      expect(find.byType(PauseButton), findsNothing);

      game.resumeRun();
      advance(game, 400);
      await tester.pump();
      expect(find.byType(GameOverScreen), findsOneWidget);
      expect(find.byType(PausedScreen), findsNothing);
    });
  });

  group('the best score survives a restart of the app', () {
    testWidgets('a finished run is written to the store', (
      WidgetTester tester,
    ) async {
      final InMemoryHighScoreStore store = InMemoryHighScoreStore();
      final FlappyMiataGame game = await boot(tester, store: store);
      expect(store.current, isNull, reason: 'nothing has been played yet');

      game.startRun();
      advance(game, 400);
      expect(game.model.state, RunState.dead);
      await tester.pump();

      final BestRun? saved = store.current;
      expect(saved, isNotNull, reason: 'the run was never written down');
      expect(saved!.score, game.model.score);

      // And what was written is a real run, not just a number: it decodes and
      // re-executes to the score it claims.
      expect(BestRunRecord.decode(BestRunRecord.encode(saved)), saved);
    });

    testWidgets('a second launch picks the stored best up', (
      WidgetTester tester,
    ) async {
      // THE FEATURE, stated as one test. Two separate `FlappyMiataGame`
      // objects — the closest a widget test gets to closing the app and opening
      // it again — sharing one store.
      final Replay run = provedRun();
      final int scored = replayFinalModel(run).score;
      expect(scored, greaterThan(0), reason: 'the fixture never scored');

      final InMemoryHighScoreStore store = storeHolding(run);
      final FlappyMiataGame relaunched = await boot(tester, store: store);

      expect(relaunched.hasBestScore, isTrue);
      expect(relaunched.bestScore, scored);
      expect(find.text('BEST'), findsOneWidget);
      expect(find.text('$scored'), findsOneWidget);
    });

    testWidgets('a stored run on this course comes back as the ghost', (
      WidgetTester tester,
    ) async {
      // The best run is stored as a RUN, so the thing that comes back is
      // something to race and not only a number to beat.
      final Replay run = provedRun();
      final FlappyMiataGame game =
          await boot(tester, seed: run.seed, store: storeHolding(run));

      expect(game.ghostModel, isNotNull,
          reason: 'the stored run should be on the track for the FIRST run of '
              'the session, not only after one is thrown away');
    });

    testWidgets('a stored run on a different course is not raced', (
      WidgetTester tester,
    ) async {
      // A run code carries its own seed. Replaying yesterday's ghost on today's
      // course would put a car on screen flying through pipes that are not
      // there — so the score is kept and the ghost is not.
      final Replay run = provedRun();
      final FlappyMiataGame game = await boot(
        tester,
        seed: run.seed + 1,
        store: storeHolding(run),
      );

      expect(game.hasBestScore, isTrue, reason: 'the score still counts');
      expect(game.ghostModel, isNull);
    });

    testWidgets('a best score that lands AFTER the start screen is up still '
        'appears', (WidgetTester tester) async {
      // The subtle one. Reading the store is asynchronous, so on a real device
      // the start screen is drawn first and the record arrives a few frames
      // later. A Flame overlay is rebuilt when the set of ACTIVE overlays
      // changes — and it does not change here, because the same screen is up
      // before and after. Without `GameScreenHost.revision` the record would
      // simply never appear, and it would look exactly like a store that had
      // not saved anything.
      final Replay run = provedRun();
      final int scored = replayFinalModel(run).score;
      final _SlowStore store = _SlowStore();

      final FlappyMiataGame game = await boot(tester, store: store);
      expect(game.hasBestScore, isFalse);
      expect(find.text('BEST'), findsNothing, reason: 'the store has not '
          'answered yet, so there is nothing to show');

      store.answer(
        BestRun(score: scored, code: encodeRunCode(run)),
      );
      await tester.pump();
      await tester.pump();

      expect(game.bestScore, scored);
      expect(find.text('BEST'), findsOneWidget,
          reason: 'the screen never rebuilt when the record arrived');
      expect(find.text('$scored'), findsOneWidget);
    });

    testWidgets('a tampered record is ignored and the game starts fresh', (
      WidgetTester tester,
    ) async {
      // The store hands back only records that re-execute to the score they
      // claim, so an edited number reaches the game as "no best yet" rather
      // than as an unbeatable target.
      final Replay run = provedRun();
      final InMemoryHighScoreStore store = InMemoryHighScoreStore(
        BestRun(
          score: replayFinalModel(run).score + 500,
          code: encodeRunCode(run),
        ),
      );
      // The store itself holds whatever it was given; the CHECK is in the
      // record, which is what the game reads through.
      expect(BestRunRecord.decode(BestRunRecord.encode(store.current!)), isNull);

      final FlappyMiataGame game =
          await boot(tester, seed: run.seed, store: _VerifyingStore(store));
      expect(game.hasBestScore, isFalse);
      expect(game.ghostModel, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // "NEW BEST" AT THE LAYER THAT DECIDES IT.
  //
  // The four screen tests above prove the CARD renders from `isNewBest`. They
  // cannot prove the flag is right, because they set it themselves. These drive
  // a real `FlappyMiataGame` — the implementation the app actually wires up —
  // and check the flag the game works out for itself, together with what it does
  // and does not write to storage.
  // ---------------------------------------------------------------------------

  group('a record is only claimed when one was actually set', () {
    testWidgets('a first run scoring nothing records a best and claims none', (
      WidgetTester tester,
    ) async {
      final CountingHighScoreStore store = CountingHighScoreStore();
      final FlappyMiataGame game = await boot(tester, store: store);

      game.startRun();
      advance(game, 400);

      // The fixture has to be the case under test: dead, and with no points.
      expect(game.model.state, RunState.dead);
      expect(game.score, 0, reason: 'this run was supposed to score nothing');

      // A best of zero IS recorded — the game has been played, and the start
      // screen says so honestly. What must not happen is the congratulation.
      expect(game.hasBestScore, isTrue);
      expect(game.bestScore, 0);
      expect(store.saves, 1, reason: 'the first run is always worth storing');

      expect(game.isNewBest, isFalse,
          reason: 'a run that passed no obstacle beat nothing');

      await tester.pump();
      expect(find.byType(GameOverScreen), findsOneWidget);
      expect(find.text('NEW BEST'), findsNothing);
    });

    testWidgets('a run that scores really does claim the record', (
      WidgetTester tester,
    ) async {
      // The other side of the detector. Without this the two tests above would
      // be satisfied by an `isNewBest` hard-wired to false, and the banner would
      // be gone from the game with the suite still green.
      final CountingHighScoreStore store = CountingHighScoreStore();
      final FlappyMiataGame game = await boot(tester, store: store);
      driveToDeath(game, witnessInputs());

      expect(game.model.state, RunState.dead);
      expect(game.score, greaterThan(0),
          reason: 'the witness was supposed to clear obstacles');
      expect(game.isNewBest, isTrue);
      expect(store.saves, 1);

      await tester.pump();
      expect(find.text('NEW BEST'), findsOneWidget);
    });

    testWidgets('a stored best of zero is not beaten by a fresh zero', (
      WidgetTester tester,
    ) async {
      // THE PERSISTENCE HALF OF THE SAME BOUNDARY. The device already holds a
      // verified best of 0; this run also scores 0. Nothing was beaten, so
      // nothing may be claimed and nothing may be written.
      final Replay nothing = zeroScoringRun();
      final CountingHighScoreStore store = CountingHighScoreStore(
        BestRun(score: 0, code: encodeRunCode(nothing)),
      );
      final FlappyMiataGame game = await boot(tester, store: store);

      // The seeded record really did come back, or everything below is about a
      // game that has never been played.
      expect(game.hasBestScore, isTrue);
      expect(game.bestScore, 0);
      expect(store.saves, 0, reason: 'nothing has been played yet');

      game.startRun();
      advance(game, 400);
      expect(game.model.state, RunState.dead);
      expect(game.score, 0);

      expect(game.isNewBest, isFalse);
      expect(store.saves, 0,
          reason: 'a fresh 0 against a stored 0 must not be written');
    });

    testWidgets('tying an existing record claims nothing and writes nothing', (
      WidgetTester tester,
    ) async {
      // The same defect with a non-zero number, which is why fixing only the
      // zero case would not have been a fix. The stored record and the run about
      // to be played are the SAME run, so the score comes out equal by
      // construction rather than by luck.
      final List<bool> inputs = witnessInputs();
      final Replay recorded = recordedFrom(inputs);
      final int scored = replayFinalModel(recorded).score;
      expect(scored, greaterThan(0));

      final CountingHighScoreStore store = CountingHighScoreStore(
        BestRun(score: scored, code: encodeRunCode(recorded)),
      );
      final FlappyMiataGame game = await boot(tester, store: store);
      expect(game.bestScore, scored);

      driveToDeath(game, inputs);
      expect(game.score, scored, reason: 'the replayed run scored differently');

      expect(game.isNewBest, isFalse,
          reason: 'equalling a record is not setting one');
      expect(store.saves, 0);

      await tester.pump();
      expect(find.text('NEW BEST'), findsNothing);
    });

    testWidgets('the claim is cleared when the next run starts', (
      WidgetTester tester,
    ) async {
      // A latch that never resets would leave the banner on every card for the
      // rest of the session.
      final FlappyMiataGame game = await boot(tester);
      driveToDeath(game, witnessInputs());
      expect(game.isNewBest, isTrue);

      game.restartRun();
      expect(game.isNewBest, isFalse);
    });

    testWidgets('assist is off by default, and turning it on changes no run', (
      WidgetTester tester,
    ) async {
      // THE WIRING VERSION of the claim `test/assist_test.dart` makes about the
      // solver in isolation. This one goes through the real game object — the
      // implementation the app actually builds — including the per-frame call
      // in `update` and the layer that reads the result.
      final List<bool> inputs = witnessInputs();

      final FlappyMiataGame off = await boot(tester);
      expect(off.assistEnabled, isFalse,
          reason: 'assist has to be off until somebody asks for it');
      driveToDeath(off, inputs);

      final FlappyMiataGame on = await boot(tester);
      on.toggleAssist();
      expect(on.assistEnabled, isTrue);

      // Driven in two halves so the middle can be inspected: the point of the
      // pause is to catch the assist actually producing something, which is what
      // stops the comparison below being between two runs where it never ran.
      final int half = inputs.length ~/ 2;
      for (int i = 0; i < half; i++) {
        if (inputs[i]) on.startRun();
        advance(on, 1);
      }
      expect(on.model.state, RunState.playing);
      expect(on.advice, isNotNull,
          reason: 'assist was on for half a run and never said anything, so '
              'the comparison below would prove nothing');
      expect(on.advice!.path, isNotEmpty);

      for (int i = half; i < inputs.length; i++) {
        if (inputs[i]) on.startRun();
        advance(on, 1);
      }
      advance(on, driveTail);

      expect(on.model, off.model, reason: 'the same taps gave a different run');
      expect(on.score, off.score);
      expect(on.riskScore, off.riskScore);
      expect(on.score, greaterThan(0), reason: 'neither run went anywhere');

      // And it can be turned back off.
      on.toggleAssist();
      expect(on.assistEnabled, isFalse);
      expect(on.advice, isNull);
    });

    testWidgets('a better record arriving late withdraws the claim', (
      WidgetTester tester,
    ) async {
      // The remaining window on the same defect. Reading the store is
      // asynchronous, so a run can finish — and beat the best KNOWN, which is
      // nothing yet — before the store answers. When the answer turns out to be
      // a bigger number, the run did not set the record after all, and the card
      // must stop saying it did.
      final _SlowStore store = _SlowStore();
      final FlappyMiataGame game = await boot(tester, store: store);
      expect(game.hasBestScore, isFalse, reason: 'the store has not answered');

      driveToDeath(game, witnessInputs());
      final int scored = game.score;
      expect(scored, greaterThan(0));
      expect(game.isNewBest, isTrue,
          reason: 'it beat the only record it knew about, which was none');

      // Now the store answers, with something better.
      store.answer(BestRun(
        score: scored + 10,
        code: encodeRunCode(recordedFrom(witnessInputs())),
      ));
      await tester.pump();
      await tester.pump();

      expect(game.bestScore, scored + 10, reason: 'the record was not adopted');
      expect(game.isNewBest, isFalse,
          reason: 'the card is still congratulating a run that lost');

      await tester.pump();
      expect(find.text('NEW BEST'), findsNothing);
    });

    testWidgets('a WORSE record arriving late leaves the claim standing', (
      WidgetTester tester,
    ) async {
      // The other side, so the withdrawal above is not simply "always clear it".
      final _SlowStore store = _SlowStore();
      final FlappyMiataGame game = await boot(tester, store: store);
      driveToDeath(game, witnessInputs());
      final int scored = game.score;
      expect(game.isNewBest, isTrue);

      store.answer(BestRun(score: 0, code: encodeRunCode(zeroScoringRun())));
      await tester.pump();
      await tester.pump();

      expect(game.bestScore, scored, reason: 'the record moved DOWN');
      expect(game.isNewBest, isTrue,
          reason: 'this run really did beat the stored record');
    });

    testWidgets('the claim survives every frame the card is up', (
      WidgetTester tester,
    ) async {
      // `_captureFinishedRun` runs again on every frame after the run ends, and
      // by its second pass the record it just set IS the score — so anything
      // recomputed there would say NEW BEST once and then stop. Six hundred more
      // frames is ten seconds of looking at the card.
      final FlappyMiataGame game = await boot(tester);
      driveToDeath(game, witnessInputs());
      expect(game.isNewBest, isTrue);

      advance(game, 600);
      expect(game.isNewBest, isTrue,
          reason: 'the banner flickered off while the card was still up');
    });
  });
}

/// A store that does not answer until it is told to.
///
/// Stands in for the thing that cannot be arranged with an in-memory store: a
/// read that is still in flight while the start screen is already on screen,
/// which is what every read on a real device is.
class _SlowStore implements HighScoreStore {
  final Completer<BestRun?> _gate = Completer<BestRun?>();

  /// Lets the pending [load] finish.
  void answer(BestRun? best) => _gate.complete(best);

  @override
  Future<BestRun?> load() => _gate.future;

  @override
  Future<void> save(BestRun best) async {}
}

/// A store that puts its contents through the real encode/decode path.
///
/// [InMemoryHighScoreStore] deliberately hands back exactly what it was given —
/// it is a box, not a check — so a test about a TAMPERED record needs the
/// verification step the platform store performs on the way out. This is that
/// step, and nothing else.
class _VerifyingStore implements HighScoreStore {
  final InMemoryHighScoreStore inner;

  _VerifyingStore(this.inner);

  @override
  Future<BestRun?> load() async {
    final BestRun? raw = await inner.load();
    return raw == null ? null : BestRunRecord.decode(BestRunRecord.encode(raw));
  }

  @override
  Future<void> save(BestRun best) => inner.save(best);
}
