/// The real entry point: the rules in `lib/game/`, drawn and made playable.
///
/// WHAT THIS FILE IS, AND WHAT IT IS NOT
///
/// It is the wiring between two halves that deliberately know nothing about
/// each other. `lib/game/` owns the rules and cannot draw — it has no Flame and
/// no Flutter import at all. This file can draw and owns no rules: every number
/// that decides how the game *behaves* lives in `GameModel`, and if one starts
/// creeping in here it belongs over there instead.
///
/// It is also deliberately PLAIN. Flat rectangles, one colour each, no sprites,
/// no menus, no animation beyond the game itself. Presentation is `lib/ui/`,
/// that directory is owned by a teammate, and this file leaves the design space
/// empty on purpose. The point of this file is that the game can be run and new
/// components can be tested against something that works — not that it looks
/// finished.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:flappymiata/game/course_seed.dart';
import 'package:flappymiata/game/game_model.dart';
import 'package:flappymiata/game/replay.dart';
import 'package:flappymiata/game/run_code.dart';
import 'package:flappymiata/ui/game_screens.dart';
import 'package:flappymiata/ui/high_score_store.dart';

// -----------------------------------------------------------------------------
// DRAW ORDER.
//
// Flame paints sibling components in ascending `priority`: the lowest number is
// laid down first and everything after it lands on top. So the layer that has
// to stay readable needs the HIGHER number, and these constants are the only
// place that decision is recorded.
//
// WHY THIS IS SPELLED OUT RATHER THAN LEFT TO CHANCE: the obstacles scroll
// across the FULL width of the screen, so the score is not tucked away in a
// safe corner — every pipe passes over it, a few seconds after the run starts.
// The dev harness hit exactly this: it painted the world onto the canvas AFTER
// the component tree had already drawn, which puts the pipes over the text
// unconditionally and no component priority can undo it. An ordering that
// depends on which line of code ran last is invisible in review; an ordering
// that is a number attached to a layer is not.
//
// WHY THE CAR MOVED OUT OF THE WORLD LAYER WHEN THE GHOST ARRIVED: the ghost
// has to sit BEHIND the live car and IN FRONT OF the pipes, which is a
// three-way ordering and therefore three layers. Leaving all of it inside one
// component would have made that ordering a matter of which `canvas.draw` call
// came first inside a `render` method — exactly the invisible, line-order
// dependency the paragraph above exists to rule out. Pipes still scroll the
// full width and still cover everything numbered below them, ghost included.
// -----------------------------------------------------------------------------

/// The pipes. Lowest of the playfield layers, so both cars are drawn on top of
/// them.
const int _worldPriority = 0;

/// The recorded best run's car. Above the pipes so it can be seen at all,
/// below the live car so it can never obscure the one the player is steering.
const int _ghostPriority = 10;

/// The live car.
const int _carPriority = 20;

/// The collision-box overlay. Between the world and the HUD on purpose: it has
/// to cover the pipes it is describing, and it must not cover the score.
const int _debugPriority = 50;

/// The score panel. Set far above [_worldPriority] rather than one step above
/// it, so a layer added later — `lib/ui/` will want some — has somewhere to sit
/// in between without anyone renumbering these.
const int _hudPriority = 100;

/// The course everybody gets when the daily challenge is switched off: seed 0,
/// which `lib/game/course_seed.dart` proves is bit-for-bit the shipped hash.
const int classicCourseSeed = 0;

/// Whether the app plays today's date-seeded course or the classic one.
///
/// `const`, so switching it off removes the calendar lookup from the build
/// entirely rather than leaving a branch nobody takes.
const bool kDailyChallenge = true;

/// Today's course seed.
///
/// THE CALENDAR IS READ HERE AND NOWHERE ELSE. `lib/game/` has no clock in it —
/// no frame duration, no calendar, no random number generator — and that is not
/// a stylistic preference, it is what makes every rule in there a function of
/// its arguments and therefore testable by comparing it to an expected value.
/// `dailySeed` accordingly takes a year, a month and a day as three plain
/// integers and has no idea which of them is today. This file is a renderer, it
/// already knows about wall-clock time because Flame hands it a frame duration
/// sixty times a second, and one more fact about the real world costs it
/// nothing.
///
/// LOCAL date rather than UTC, deliberately: "today's challenge" should change
/// at the player's midnight, not at Greenwich's. The consequence is that two
/// players in different time zones can briefly be on different days' courses,
/// which is the right trade — the alternative is a challenge that rolls over in
/// the middle of somebody's afternoon.
int todaysCourseSeed() {
  if (!kDailyChallenge) return classicCourseSeed;
  final DateTime now = DateTime.now();
  return dailySeed(now.year, now.month, now.day);
}

/// FLIP THIS TO SEE THE COLLISION BOXES. One boolean, at the top of the file,
/// off in anything shipped.
///
/// WHY THIS SURVIVES RATHER THAN BEING DELETED ONCE IT HAD FOUND ITS BUG:
///
/// The car sprite once drew 2.93x wider than the box it was supposed to be
/// standing in, so its nose and tail passed straight through pipes without
/// dying. Nothing about that was visible in the source — the model was right,
/// the renderer was self-consistent, and the mismatch existed only on screen.
/// It was eventually pinned down by measuring pixels off a screenshot. Drawing
/// the boxes over the picture answers the same question in one glance, and goes
/// on answering it for every change made after this one.
///
/// `const` rather than a mutable field, so the compiler can drop the overlay
/// and its paints out of a release build entirely while it is false.
const bool kShowCollisionBoxes = false;

void main() {
  runApp(const FlappyMiataApp());
}

/// THIS WIDGET IS DELIBERATELY THIN.
///
/// `lib/main.dart` is the one file both people in this repo have to touch, so
/// every line here is a line that can collide on merge. Its job is wiring only:
/// start the app, hand Flutter a game. Input and drawing live on the game
/// below; gameplay lives in `lib/game/`; screens and menus belong in `lib/ui/`,
/// where one person can own a file outright.
class FlappyMiataApp extends StatelessWidget {
  const FlappyMiataApp({super.key});

  @override
  Widget build(BuildContext context) {
    // `.controlled` lets the widget's own State create and keep the game
    // instance. Building `GameWidget(game: FlappyMiataGame())` directly would
    // construct a fresh game on every rebuild and throw away the run in
    // progress.
    return const GameWidget<FlappyMiataGame>.controlled(
      gameFactory: FlappyMiataGame.new,
    );
  }
}

/// The renderer half. Everything in this class may import Flame and Flutter;
/// nothing in it is allowed to decide how the game behaves.
///
/// It owns one [GameModel] snapshot and the two layers that read it —
/// [_WorldLayer] underneath and [_ScorePanel] on top. Neither layer holds state
/// of its own: each draws whatever snapshot this class is holding at the moment
/// it is asked to.
///
/// `TapCallbacks` is mixed in at the GAME level rather than onto a component,
/// because a tap anywhere on screen should count. A `FlameGame` is itself a
/// Component and reports every point inside the canvas as its own, so the whole
/// surface becomes the tap target with no invisible button to size or place.
class FlappyMiataGame extends FlameGame
    with TapCallbacks
    implements GameScreenHost {
  /// Which course this session plays. Fixed for the life of the game object, so
  /// a restart puts the player on the same obstacles — otherwise "beat your
  /// ghost" would be a different question every attempt.
  final int courseSeed;

  /// Where the best score is kept between sessions.
  ///
  /// INJECTED rather than constructed here, because the real one talks to a
  /// platform plugin and `flutter test` has no platform under it. A widget test
  /// hands in [InMemoryHighScoreStore] and gets a game that behaves identically
  /// without touching a disk — including the "the app has been played before"
  /// case, which is otherwise impossible to set up.
  final HighScoreStore highScoreStore;

  FlappyMiataGame({int? courseSeed, HighScoreStore? highScoreStore})
    : courseSeed = courseSeed ?? todaysCourseSeed(),
      highScoreStore = highScoreStore ?? SharedPreferencesHighScoreStore();

  /// The live run: the model, plus the record of which frames were taps.
  ///
  /// WHY A RECORDER RATHER THAN A BARE `GameModel`, which is what this used to
  /// be: the model is still the single source of truth about the run and is
  /// still immutable and still replaced rather than mutated. The recorder is a
  /// thin wrapper that does exactly two extra things — it steps at a FIXED
  /// timestep, and it writes down the frames the player tapped on. Both are
  /// required for the run to be reproducible later, and neither is a rule.
  ///
  /// The consequence to remember when editing this file: the run is advanced by
  /// `_run.step()` and nothing else. There is no `_model = ...` assignment left
  /// to forget the return value of.
  late ReplayRecorder _run = ReplayRecorder(seed: courseSeed);

  /// Turns Flame's real, jittery frame durations into whole fixed steps.
  ///
  /// WHY THE MODEL NO LONGER SEES `dt` DIRECTLY: it used to, and the game
  /// played perfectly well — but the run was then a function of the device's
  /// frame pacing, so it could not be written down. Two players who tapped at
  /// exactly the same moments would get different runs on a 60 Hz and a 120 Hz
  /// screen. Spending real time in fixed [replayFrameSeconds] chunks makes the
  /// simulation frame-rate independent, which is what a recording, a ghost and
  /// a verified score all rest on. See `lib/game/replay.dart`.
  final FixedStepAccumulator _clock = FixedStepAccumulator();

  /// The best run ON THIS COURSE, kept so the next one can race it.
  ///
  /// Separate from [_bestScore], and the distinction is worth stating because
  /// merging the two was the first version of this and it was wrong: the ghost
  /// has to be a run of the SAME obstacles or it is racing a different game,
  /// while the best score is the player's record and belongs to the player
  /// rather than to a course. On the daily challenge those are different things
  /// every day.
  Replay? _ghostSource;

  /// The score [_ghostSource] achieved.
  int _ghostScore = 0;

  /// The best score ever recorded on this device, across every course.
  ///
  /// Loaded from [highScoreStore] at start-up and written back the moment it is
  /// beaten. Only ever increases within a session.
  int _bestScore = 0;

  /// False until a best score is known, so the screens can tell "no best yet"
  /// from a best of zero. A best of zero is a real thing — a run that died
  /// before the first pipe — and showing it as "BEST 0" is honest where showing
  /// nothing would be a lie about a game that has been played.
  bool _hasBestScore = false;

  /// Whether the world is stopped.
  ///
  /// THIS IS THE WHOLE OF PAUSING, and it needs no clock, no timer and no new
  /// state in the model. Time reaches the game in exactly one way — `tick(dt)`,
  /// called from [update] — so not calling it IS pausing. The model is immutable,
  /// so the snapshot the renderer is holding stays exactly what it was and
  /// resuming continues from it rather than from anything reconstructed.
  ///
  /// Note what is NOT done here: the accumulator is not asked for steps while
  /// paused, so the seconds spent on the pause screen are never banked and
  /// cannot be spent as a burst of catch-up frames on the way out. `RunState`
  /// has three values and none of them is `paused`, on purpose — stopping the
  /// world is a rendering decision, and this is the renderer.
  bool _paused = false;

  /// The recorded best run, being replayed alongside the live one.
  ///
  /// Null until there is a best run to race, and null again for the first run
  /// of a session. It holds a `ReplayPlayer`, which is the SAME driver the
  /// verifier and the tests use — the ghost is not a special rendering-side
  /// simulation, it is the recording being executed.
  ReplayPlayer? _ghost;

  /// Read-only view of the live snapshot, for anything that draws.
  ///
  /// Public so that `lib/ui/` can render from it without this file handing out
  /// a way to change it.
  GameModel get model => _run.model;

  /// The ghost's snapshot, or null when there is nothing to race.
  GameModel? get ghostModel => _ghost?.model;

  // ---------------------------------------------------------------------------
  // GameScreenHost — everything the screens in `lib/ui/` are allowed to see.
  //
  // Getters only, plus four verbs. There is no way through this interface to
  // reach the model or the replay, which is what stops a screen growing a rule.
  // ---------------------------------------------------------------------------

  /// Bumped when a screen's CONTENT changes without the screen itself changing.
  ///
  /// The only case in this game is the best score arriving from storage after
  /// the start screen is already up. Everything else a screen displays changes
  /// at the same moment the screen does, and Flame rebuilds an overlay when the
  /// active set changes.
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  @override
  Listenable get revision => _revision;

  @override
  int get score => _run.model.score;

  @override
  int get bestScore => _bestScore;

  @override
  bool get hasBestScore => _hasBestScore;

  @override
  bool get paused => _paused;

  /// The first tap of a run, from the start screen.
  ///
  /// Queued through the recorder rather than applied to the model, exactly as a
  /// tap on the playfield is: input has to land on the fixed frame grid or the
  /// run cannot be written down. See [onTapDown].
  @override
  void startRun() {
    if (_run.finished) return;
    _run.tap();
    _syncScreens();
  }

  @override
  void pauseRun() {
    // Only a live run can be paused. Pausing on the start line or after a crash
    // would put up a screen with nothing behind it to resume.
    if (_paused || _run.model.state != RunState.playing) return;
    _paused = true;
    _syncScreens();
  }

  @override
  void resumeRun() {
    if (!_paused) return;
    _paused = false;
    _syncScreens();
  }

  @override
  void restartRun() {
    _paused = false;
    _startRun();
    _syncScreens();
  }

  /// Puts the right screen up for the state the game is in.
  ///
  /// Called after every input and once per frame. The diff against
  /// [gameScreenOverlays] is what makes calling it every frame free: Flame's
  /// `add`/`remove` return without notifying when the set is already right, so
  /// the widget tree is rebuilt only when the screen genuinely changes.
  void _syncScreens() {
    final Set<String> wanted =
        overlaysFor(state: _run.model.state, paused: _paused);
    for (final String name in gameScreenOverlays) {
      if (wanted.contains(name)) {
        overlays.add(name);
      } else {
        overlays.remove(name);
      }
    }
  }

  /// The car sprite, loaded once and shared by the two layers that draw a car.
  ///
  /// Owned here rather than by either layer because both need it and neither
  /// owns the other. Loading it twice would put the same 286x120 image in
  /// memory twice and, worse, let the two layers disagree about whether it had
  /// finished loading.
  ui.Image? carImage;

  late final _ScorePanel _panel;

  @override
  Color backgroundColor() => const Color(0xFF10233F);

  @override
  Future<void> onLoad() async {
    await super.onLoad();

    // THE SPRITE IS LOADED WITHOUT BLOCKING THE GAME ON IT.
    //
    // Flame does not consider a game loaded until every `onLoad` it is waiting
    // on has returned, and until then there is no game loop and no input — so
    // awaiting a file read here means the whole game is held up by an image.
    // Both car layers already draw nothing while [carImage] is null, so the
    // cost of not waiting is at most a frame or two with the pipes and the
    // backdrop but no car, and the benefit is that the game is alive, ticking
    // and accepting taps from its very first frame.
    //
    // It also makes the game testable. `flutter test` resolves an asset through
    // real asynchronous I/O that a `pump()` alone never advances, so a game
    // that blocks on one never finishes loading in a widget test — which is
    // exactly why the ghost wiring in `test/widget_test.dart` could not be
    // checked at all until this stopped being awaited.
    unawaited(_loadCarSprite());

    // The screens own themselves. This file says which ones exist and, in
    // `_syncScreens`, which one is up; it does not lay any of them out.
    registerGameScreens(this, this);

    _panel = _ScorePanel();
    // Added in this order for readability only. The priorities the classes
    // carry are what actually decide who covers whom, so reordering these
    // entries changes nothing on screen — which is the point of using
    // priorities rather than insertion order.
    await addAll(<Component>[
      _BackdropLayer(),
      _WorldLayer(),
      _GhostLayer(),
      _CarLayer(),
      _panel,
    ]);

    // Added only when it is wanted. The alternative — always add it and return
    // early inside `render` — leaves a component in the tree being asked sixty
    // times a second to do nothing. [kShowCollisionBoxes] is `const`, so this
    // branch and everything it reaches are dead code the compiler can drop.
    if (kShowCollisionBoxes) {
      await add(_DebugOverlay());
    }

    // So the score and the start screen are on screen for the very first frame,
    // rather than appearing only once `update` has run once.
    _panel.text = _hudText;
    _syncScreens();

    // Started only now that [_panel] exists, because the load writes to it when
    // it lands. Same argument as the sprite for not awaiting it: reading a
    // preferences store goes through a platform channel, and a game that will
    // not start until a disk answers is a game that can be held up by one.
    // Everything above already copes with there being no best score — that is
    // the state a fresh install is in — so the answer is folded in whenever it
    // arrives.
    unawaited(_loadBestScore());
  }

  /// Decodes the car sprite into [carImage].
  Future<void> _loadCarSprite() async {
    final ByteData data = await rootBundle.load(
      'assets/sprites/miatasprite.png',
    );
    final ui.Codec codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(),
    );
    carImage = (await codec.getNextFrame()).image;
    codec.dispose();
  }

  /// Reads the stored best run, if there is one that checks out.
  ///
  /// The store re-executes the run before handing it back (see
  /// `lib/ui/high_score_store.dart`), so anything that arrives here is a score
  /// somebody really got. A record that no longer verifies — a hand-edited
  /// number, or a run recorded before the difficulty ramp changed what those
  /// taps score — comes back null and is simply not shown.
  ///
  /// THE GHOST IS ONLY REVIVED ON A MATCHING COURSE. A run code carries its own
  /// seed, and racing a recording made on a different course would put a car on
  /// screen flying through pipes that are not there.
  Future<void> _loadBestScore() async {
    final BestRun? stored = await highScoreStore.load();
    if (stored == null) return;

    // A later run may already have finished and beaten it while the load was in
    // flight. Taking the larger keeps this from ever moving the number down.
    if (!_hasBestScore || stored.score > _bestScore) {
      _bestScore = stored.score;
      _hasBestScore = true;
    }

    final Replay? replay = stored.replay;
    if (replay != null &&
        replay.seed == courseSeed &&
        (_ghostSource == null || stored.score > _ghostScore)) {
      _ghostSource = replay;
      _ghostScore = stored.score;

      // Put it on the track for the run that is about to start, not only for
      // the one after that. `_startRun` is the other place a ghost is created,
      // and it is not called for the FIRST run of a session — so without this
      // line a player who came back to beat yesterday's run would have to throw
      // one away before the thing they came to race appeared.
      //
      // Guarded on `ready`, because a load that landed mid-run would otherwise
      // drop a ghost into the middle of the track from a standing start.
      if (_run.model.state == RunState.ready) {
        _ghost = _ghostPlayerFor(replay);
      }
    }
    _panel.text = _hudText;

    // The start screen is ALREADY on screen by the time this lands, and it is
    // showing "no best yet". An overlay is rebuilt when the set of ACTIVE
    // overlays changes, and that set has not changed — so this is the one place
    // the screens have to be told about a change they cannot see for
    // themselves. See [GameScreenHost.revision].
    _revision.value++;
  }

  /// A tap means "flap" during a run and "start again" once the run is over.
  ///
  /// The tap is QUEUED rather than applied here. A touch handler fires whenever
  /// the operating system feels like it, possibly twice between two frames, and
  /// a recording can only express input on the frame grid. `ReplayRecorder.tap`
  /// therefore lands the tap on the next fixed step — which is also what the
  /// model would have done anyway, since a flap assigns velocity and two flaps
  /// inside one frame produce exactly one flap's worth of motion.
  ///
  /// REACHED ONLY WHILE A RUN IS LIVE, now that there are screens: the start,
  /// paused and game-over overlays each cover the surface and consume their own
  /// taps. The `finished` branch is kept anyway, because it is the behaviour the
  /// game has always had and the one thing that must not change is what a tap on
  /// the PLAYFIELD means. If a screen ever fails to appear, the game is still
  /// playable rather than stuck.
  @override
  void onTapDown(TapDownEvent event) {
    // A tap that arrives while the world is stopped is not an input to the run.
    // It cannot normally happen — the paused screen is over the whole surface —
    // but a flap queued here would be spent the instant the game resumed, on a
    // frame the player was not looking at.
    if (_paused) return;

    if (_run.finished) {
      _startRun();
    } else {
      _run.tap();
    }
    _panel.text = _hudText;
    _syncScreens();
  }

  /// Begins a fresh run on the same course, and puts the best run so far on the
  /// track alongside it.
  void _startRun() {
    _run = ReplayRecorder(seed: courseSeed);

    final Replay? best = _ghostSource;
    _ghost = best == null ? null : _ghostPlayerFor(best);
  }

  /// A replay driver for [best], wound forward to the frame that run began on.
  ///
  /// SKIP THE GHOST'S OWN THINKING TIME. A recording includes every frame from
  /// the moment the run object was created, including however long its player
  /// sat looking at the start screen. Those frames do nothing — the model is
  /// `ready` and `tick` returns the receiver — but replaying them would leave
  /// the ghost idling on the start line while the live car drove off.
  /// Fast-forwarding to the frame of its first tap lines the two runs up at the
  /// moment each of them actually began, which is the only alignment that makes
  /// a race mean anything.
  ///
  /// A recording with NO taps never began at all, so the whole thing is lead-in:
  /// the ghost is wound to its end and parks on the start line, which is exactly
  /// where that run spent every frame of its life.
  ///
  /// ONE FUNCTION, TWO CALLERS — a restart, and a best run arriving from storage
  /// while the player is still on the start line. A second copy of the
  /// fast-forward would be a second chance to line the race up differently.
  ReplayPlayer _ghostPlayerFor(Replay best) {
    final ReplayPlayer ghost = ReplayPlayer(best);
    final int leadIn =
        best.tapFrames.isEmpty ? best.frames : best.tapFrames.first;
    for (int i = 0; i < leadIn; i++) {
      ghost.step();
    }
    return ghost;
  }

  @override
  void update(double dt) {
    super.update(dt);

    // PAUSING IS THIS LINE. The accumulator is not asked for steps, so `tick`
    // is never called and the model — being immutable — is still exactly the
    // snapshot it was when the player hit pause. Resuming picks that snapshot
    // up rather than rebuilding anything, because there is nothing to rebuild.
    //
    // The real seconds that pass while paused are not banked either: they are
    // never handed to the accumulator at all, so the game cannot come out of a
    // pause owing itself a burst of catch-up frames.
    if (!_paused) {
      // THE ONE PLACE REAL TIME ENTERS. Flame measures how long the frame took;
      // the accumulator turns that into a whole number of fixed steps, and the
      // model never learns that a clock was involved. That indirection is why an
      // identical run can be replayed exactly in a test where no real time
      // passes at all — and why the ghost stays in step with the live car on a
      // device that stutters.
      final int steps = _clock.stepsFor(dt);
      for (int i = 0; i < steps; i++) {
        _run.step();

        // The ghost only moves once the live run has actually started. Until the
        // first tap the live car is frozen on the start line, and a ghost that
        // set off without it would be racing nobody.
        if (_run.model.state != RunState.ready) {
          _ghost?.step();
        }
      }

      _captureFinishedRun();
    }

    _panel.text = _hudText;
    _syncScreens();
  }

  /// Files a finished run: as the ghost for the next attempt, and — if it beat
  /// the record — as the stored best.
  ///
  /// Runs on every frame after the run ends and is idempotent, by the same trick
  /// it always used: after the first pass `_ghostSource` is non-null and
  /// `score > _ghostScore` is false, so the body does nothing. No "have I
  /// already saved this" flag to get out of step with the thing it describes.
  ///
  /// THE FIRST FINISHED RUN IS ALWAYS KEPT AS THE GHOST, however badly it went.
  /// A ghost that only appeared once somebody scored would leave the player with
  /// nothing to race on exactly the attempts where a reference would help most.
  /// The BEST SCORE is not kept that way — it only moves upward — because a
  /// record that a bad run could lower is not a record.
  void _captureFinishedRun() {
    if (!_run.finished) return;
    final int score = _run.model.score;

    if (_ghostSource == null || score > _ghostScore) {
      _ghostScore = score;
      _ghostSource = _run.replay;
    }

    if (!_hasBestScore || score > _bestScore) {
      _bestScore = score;
      _hasBestScore = true;
      // Stored as a RUN, not as a number: `lib/ui/high_score_store.dart` plays
      // it back on load and only believes the score if the run really produces
      // it. Fire and forget — a write that fails must not interrupt a game.
      unawaited(
        highScoreStore.save(
          BestRun(score: score, code: encodeRunCode(_run.replay)),
        ),
      );
    }
  }

  /// The score and the record, on the panel that stays up during play.
  ///
  /// The hints that used to live here — "tap to start", "tap to restart" — have
  /// moved to the screens in `lib/ui/`, which are on screen in exactly the two
  /// states that used to show them and have room to say more than three words.
  String get _hudText {
    final String score = 'score: ${_run.model.score}';
    return _hasBestScore ? '$score\nbest: $_bestScore' : score;
  }
}

/// Everything that scrolls: both pipes of every obstacle, and the car. Sits at
/// [_worldPriority], i.e. underneath the score.
///
/// ONE component for the whole world rather than one component per obstacle,
/// because `tick` rebuilds the obstacle list from scratch every frame. The
/// model already owns those objects; mirroring them into a component tree would
/// mean adding and removing components sixty times a second in order to display
/// data that is already sitting in a field.
class _BackdropLayer extends Component with HasGameReference<FlappyMiataGame> {
  _BackdropLayer() : super(priority: -100);

  static final Paint _sky = Paint()
    ..shader = ui.Gradient.linear(
      const Offset(0, 0),
      const Offset(0, 900),
      const <Color>[Color(0xFF173B62), Color(0xFF4C7E92)],
    );
  static final Paint _horizon = Paint()..color = const Color(0xFF78A88D);
  static final Paint _hill = Paint()..color = const Color(0xFF5F9B8A);
  static final Paint _cloud = Paint()..color = const Color(0xB8F4FBF4);
  static final Paint _ground = Paint()..color = const Color(0xFF264B3D);

  @override
  void render(Canvas canvas) {
    final Size size = game.size.toSize();
    canvas.drawRect(Offset.zero & size, _sky);
    final Path hills = Path()
      ..moveTo(0, size.height * 0.70)
      ..lineTo(size.width * 0.16, size.height * 0.57)
      ..lineTo(size.width * 0.31, size.height * 0.70)
      ..lineTo(size.width * 0.49, size.height * 0.53)
      ..lineTo(size.width * 0.68, size.height * 0.70)
      ..lineTo(size.width * 0.84, size.height * 0.59)
      ..lineTo(size.width, size.height * 0.70)
      ..close();
    canvas.drawPath(hills, _hill);
    _drawCloud(canvas, Offset(size.width * 0.20, size.height * 0.18), 0.9);
    _drawCloud(canvas, Offset(size.width * 0.76, size.height * 0.29), 0.65);
    canvas.drawRect(
      Rect.fromLTWH(0, size.height * 0.70, size.width, size.height * 0.06),
      _horizon,
    );
    canvas.drawRect(
      Rect.fromLTWH(0, size.height * 0.76, size.width, size.height * 0.24),
      _ground,
    );
  }

  void _drawCloud(Canvas canvas, Offset center, double scale) {
    final double width = 104 * scale;
    final double height = 24 * scale;
    final RRect cloud = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: width, height: height),
      Radius.circular(height / 2),
    );
    canvas.drawRRect(cloud, _cloud);
    canvas.drawCircle(
      center.translate(-width * 0.20, -height * 0.22),
      height * 0.65,
      _cloud,
    );
    canvas.drawCircle(
      center.translate(width * 0.12, -height * 0.34),
      height * 0.82,
      _cloud,
    );
  }
}

class _WorldLayer extends Component with HasGameReference<FlappyMiataGame> {
  _WorldLayer() : super(priority: _worldPriority);

  static const double _pipeCapHeight = 44.0;

  static final Paint _pipeOutline = Paint()..color = const Color(0xFF153D2B);
  static final Paint _pipeBody = Paint()..color = const Color(0xFF2D7A4A);
  static final Paint _pipeHighlight = Paint()..color = const Color(0xFF65B96C);
  static final Paint _pipeShadow = Paint()..color = const Color(0xFF205A3A);

  @override
  void render(Canvas canvas) {
    final Vector2 screen = game.size;
    for (final Obstacle obstacle in game.model.obstacles) {
      _drawPipe(canvas, _toPixels(obstacle.topBox, screen), capAtBottom: true);
      _drawPipe(canvas, _toPixels(obstacle.bottomBox, screen));
    }
  }

  void _drawPipe(Canvas canvas, Rect box, {bool capAtBottom = false}) {
    final double capHeight = _pipeCapHeight.clamp(0, box.height);
    final Rect body = capAtBottom
        ? Rect.fromLTRB(box.left, box.top, box.right, box.bottom - capHeight)
        : Rect.fromLTRB(box.left, box.top + capHeight, box.right, box.bottom);
    final Rect cap = capAtBottom
        ? Rect.fromLTRB(box.left, box.bottom - capHeight, box.right, box.bottom)
        : Rect.fromLTRB(box.left, box.top, box.right, box.top + capHeight);

    canvas.drawRect(body, _pipeOutline);
    canvas.drawRect(body.deflate(5), _pipeBody);
    canvas.drawRect(
      Rect.fromLTRB(body.left + 7, body.top, body.left + 13, body.bottom),
      _pipeHighlight,
    );
    canvas.drawRect(
      Rect.fromLTRB(body.right - 12, body.top, body.right - 5, body.bottom),
      _pipeShadow,
    );
    canvas.drawRect(cap, _pipeOutline);
    canvas.drawRect(cap.deflate(5), _pipeBody);
    final Rect capHighlight = capAtBottom
        ? Rect.fromLTRB(cap.left + 8, cap.top + 7, cap.right - 8, cap.top + 14)
        : Rect.fromLTRB(
            cap.left + 8,
            cap.bottom - 14,
            cap.right - 8,
            cap.bottom - 7,
          );
    canvas.drawRect(capHighlight, _pipeHighlight);
    final Rect opening = capAtBottom
        ? Rect.fromLTRB(cap.left + 11, cap.top + 16, cap.right - 11, cap.top + 25)
        : Rect.fromLTRB(
            cap.left + 11,
            cap.bottom - 25,
            cap.right - 11,
            cap.bottom - 16,
          );
    canvas.drawRect(opening, _pipeShadow);
  }

}

/// How much bigger the drawn car is than its collision box.
///
/// The hitbox is ~91% of the drawn car. A slightly forgiving hitbox is the
/// convention in this genre - it reads as fair, where the reverse reads as
/// broken. Any value here is a deliberate design choice, not a fudge.
///
/// WHAT THIS REPLACED: `_miataVisualHeightScale = 1.885`, a factor applied to
/// the box's HEIGHT with the width then taken from the image's own proportions.
/// That could not have worked. The box was 108 x 120 px on the test device —
/// nearly square — while the car is 2.383 : 1, so any scale that made the
/// height look right made the width 2.93x too large, and the nose and tail of
/// the car passed through pipes untouched. The fix was not a better constant;
/// it was giving the BOX the sprite's shape, which is what `GameModel.carWidth`
/// now does. With the shapes already agreeing, a single uniform scale is the
/// only thing left to choose.
const double _spriteOversize = 1.10;

/// Draws the car sprite into the hitbox [box], scaled by one number on both
/// axes.
///
/// Not "sized from the image and then centred on the box", which is what this
/// did before and is how the two came apart: the image's proportions and the
/// box's proportions were two independent facts and nothing made them agree.
/// The box now carries the sprite's aspect — `GameModel.carWidth` is derived
/// from `carSpriteAspect` — so drawing into the box IS drawing at the right
/// shape, and the only decision left is how much bigger the picture is than the
/// box: [_spriteOversize], one constant, one meaning.
///
/// Centred rather than anchored to an edge, so the forgiveness is even: the
/// extra 10% hangs off the nose and the tail equally, and off the roof and the
/// sills equally.
///
/// ONE FUNCTION, TWO CALLERS, for the same reason [_toPixels] is one function:
/// the ghost has to be drawn exactly where the live car would have been on that
/// frame of its run. A second copy of this arithmetic that drifted by a pixel
/// would make the ghost a picture of a slightly different game.
void _drawCar(
  Canvas canvas,
  ui.Image image,
  Box box,
  Vector2 screen,
  Paint paint,
) {
  final Rect carRect = _toPixels(box, screen);
  final Rect visualRect = Rect.fromCenter(
    center: carRect.center,
    width: carRect.width * _spriteOversize,
    height: carRect.height * _spriteOversize,
  );
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    visualRect,
    paint,
  );
}

/// The car the player is steering. Above the ghost, below the HUD.
class _CarLayer extends Component with HasGameReference<FlappyMiataGame> {
  _CarLayer() : super(priority: _carPriority);

  /// Stated rather than left at the default, because the default for
  /// `drawImageRect` is `FilterQuality.low` — a single bilinear sample, which
  /// throws source pixels away when an image is minified. `miatasprite.png` is
  /// a downscaled high-resolution render, not pixel art: 286 source pixels are
  /// drawn into roughly 195, so at low quality the car's outlines crawl and
  /// shimmer as it moves. `medium` samples a mipmap chain, averaging the pixels
  /// being skipped instead of ignoring them. `none` (nearest neighbour) is the
  /// right answer for pixel art and exactly the wrong one here.
  static final Paint _spritePaint = Paint()
    ..filterQuality = FilterQuality.medium
    ..isAntiAlias = true;

  @override
  void render(Canvas canvas) {
    final ui.Image? image = game.carImage;
    if (image == null) return;
    _drawCar(canvas, image, game.model.carBox, game.size, _spritePaint);
  }
}

/// The recorded best run, driving the same course at the same time.
///
/// Sits at [_ghostPriority]: over the pipes, so it can be seen at all, and
/// under [_CarLayer], so it can never be mistaken for — or hide — the car the
/// player is actually steering. That ordering is the whole design requirement
/// for this component, and it is expressed as two numbers rather than as the
/// order of two `canvas.draw` calls inside one `render`.
class _GhostLayer extends Component with HasGameReference<FlappyMiataGame> {
  _GhostLayer() : super(priority: _ghostPriority);

  /// A flat, translucent silhouette rather than a faded copy of the sprite.
  ///
  /// `BlendMode.srcIn` replaces every pixel's colour with this one and keeps
  /// its alpha, so the result is the car's exact SHAPE in a single colour. Two
  /// reasons that is the right choice over simply lowering the opacity:
  ///
  ///  - It cannot be confused with the live car at a glance, even when the two
  ///    overlap, which is exactly when confusion would cost the player a run.
  ///  - It is unambiguous at any size and on any background. A 45%-opacity
  ///    photograph of a car over a green pipe is a smear.
  ///
  /// The colour is the panel border's teal at half alpha — already in this
  /// file's palette, and readable against both the sky and the pipes.
  static final Paint _ghostPaint = Paint()
    ..colorFilter =
        const ColorFilter.mode(Color(0x8C8BD3C7), BlendMode.srcIn)
    ..filterQuality = FilterQuality.medium
    ..isAntiAlias = true;

  @override
  void render(Canvas canvas) {
    final ui.Image? image = game.carImage;
    final GameModel? ghost = game.ghostModel;
    if (image == null || ghost == null) return;
    _drawCar(canvas, image, ghost.carBox, game.size, _ghostPaint);
  }
}

/// THE ONE CONVERSION THE MODEL REFUSES TO DO: a normalised box — 0..1 on both
/// axes — becomes pixels by multiplying x by the screen width and y by the
/// screen height.
///
/// WHY IT HAPPENS AT RENDER TIME RATHER THAN ONCE AT STARTUP: the screen size
/// is not a constant. It changes on rotation, on a window resize, on a foldable
/// opening. Converting every frame means the game is always drawn against the
/// size it actually has right now, and the model never has to be told that
/// anything moved — the numbers in it are fractions of the playfield, so they
/// were already correct at both sizes. That is also what makes a phone and a
/// tablet play an identical game.
///
/// WHY IT IS A TOP-LEVEL FUNCTION AND NOT A METHOD ON THE LAYER THAT DRAWS:
/// the debug overlay's whole job is to show where the collision boxes really
/// are. If it converted coordinates with its own slightly different copy of
/// this arithmetic, it would be capable of drawing a box somewhere the game
/// does not think it is — an instrument that can disagree with the thing it
/// measures is worse than no instrument at all. One function, both callers.
///
/// THE ASPECT COUPLING, which is why the bug this file just fixed was possible:
/// the two axes are scaled by DIFFERENT numbers, so a box's shape on screen
/// depends on the screen. `GameModel.referenceAspect` records the aspect the
/// boxes were designed at, and what a renderer at any other aspect is signing
/// up for. Nothing in the rules is affected either way, because collision is
/// tested in model coordinates and never in pixels.
Rect _toPixels(Box box, Vector2 screen) => Rect.fromLTRB(
  box.left * screen.x,
  box.top * screen.y,
  box.right * screen.x,
  box.bottom * screen.y,
);

/// Draws the collision boxes the rules actually use, straight over the picture
/// they are meant to match. Present only when [kShowCollisionBoxes] is true.
///
/// Outlines, never fills: the point is to compare a box against the art
/// underneath it, and a filled box hides the one thing being checked.
class _DebugOverlay extends Component with HasGameReference<FlappyMiataGame> {
  _DebugOverlay() : super(priority: _debugPriority);

  /// Three distinct hues rather than one debug colour, so a screenshot of this
  /// can be read without a legend: pink is the car, amber is a pipe, cyan is
  /// the middle of the gap.
  static final Paint _carOutline = Paint()
    ..color = const Color(0xFFFF2D78)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;

  static final Paint _obstacleOutline = Paint()
    ..color = const Color(0xFFFFC13B)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;

  static final Paint _gapCentreLine = Paint()
    ..color = const Color(0xFF3BE0FF)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;

  @override
  void render(Canvas canvas) {
    final Vector2 screen = game.size;

    // Obstacles first and the car last, so the car's outline stays on top on
    // the frames where it overlaps a pipe — which are exactly the frames
    // anybody turns this overlay on to look at.
    for (final Obstacle obstacle in game.model.obstacles) {
      canvas.drawRect(_toPixels(obstacle.topBox, screen), _obstacleOutline);
      canvas.drawRect(_toPixels(obstacle.bottomBox, screen), _obstacleOutline);

      // The gap centre, drawn across the obstacle's own width rather than the
      // whole screen: it is a property of this obstacle, and a full-width line
      // would read as a global guide the game does not have.
      final double centreY = obstacle.gapCentre * screen.y;
      canvas.drawLine(
        Offset(obstacle.left * screen.x, centreY),
        Offset(obstacle.right * screen.x, centreY),
        _gapCentreLine,
      );
    }

    // `game.model.carBox` — the same getter `tick` collides with, not a rect
    // rebuilt here out of the constants. Reading the model's own box is what
    // makes this overlay evidence rather than a second opinion.
    canvas.drawRect(_toPixels(game.model.carBox, screen), _carOutline);
  }
}

/// The score and record on an opaque backing panel, at [_hudPriority] — above
/// everything the world layer draws.
///
/// WHY THE BACKING IS NOT DECORATION: priority fixes the ordering, and ordering
/// alone does not fix legibility. Pale glyphs sitting directly on the bright
/// green of a pipe are a contrast problem rather than a depth one, and they
/// stay hard to read even once they are unmistakably in front. An opaque
/// rectangle underneath makes the colour behind the text a known quantity no
/// matter what is passing beneath it.
///
/// WHAT CAME OUT OF THIS CLASS WHEN THE SCREENS ARRIVED: a second, centred card
/// that said READY / TAP TO DRIVE and RUN OVER / TAP TO RESTART. `lib/ui/` now
/// puts a real screen in exactly those two states, over the top of this one, so
/// the canvas card was drawing underneath an opaque widget and saying the same
/// thing twice. This panel is the in-play HUD and nothing else; the screens are
/// in `lib/ui/game_screens.dart` and they reuse this card's colours, radius and
/// dropped border so the two read as one design.
class _ScorePanel extends PositionComponent
  with HasGameReference<FlappyMiataGame> {
  _ScorePanel()
    : super(
        // Pushed down from the top edge rather than starting at y = 0: on a
        // phone the first line would sit directly under the status bar clock
        // and the two overlap into a smear. 48 logical pixels clears it.
        position: Vector2(16, 48),
        priority: _hudPriority,
      );

  /// Breathing room between the glyphs and the edge of the panel. Without it
  /// the backing stops exactly at the ink and reads as a highlighter stripe
  /// rather than as a panel.
  static const double _padding = 8.0;

  /// THE ALPHA BYTE IS `FF` AND HAS TO STAY `FF`. The entire job of this
  /// rectangle is that pipe colour cannot show through it. Anything below full
  /// alpha quietly reintroduces the unreadable-score problem, and it would only
  /// show up in the handful of frames a pipe spends behind the text.
  static final Paint _backing = Paint()..color = const Color(0xE812263D);
  static final Paint _cardBorder = Paint()
    ..color = const Color(0xFF8BD3C7)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3;

  /// Added as a CHILD rather than drawn inside [render], because Flame draws a
  /// component's children after the component itself. That is the same
  /// low-paints-first rule as the two layer priorities above, and it is what
  /// puts the glyphs on top of their own backing instead of under it.
  final TextComponent _readout = TextComponent(
    position: Vector2(_padding, _padding),
    textRenderer: TextPaint(
      style: const TextStyle(
        color: Color(0xFFFFFFFF),
        fontSize: 20.0,
        height: 1.4,
      ),
    ),
  );

  /// Sets the text, and resizes the panel to match it.
  ///
  /// The panel is measured FROM the text instead of being given a fixed size,
  /// because the content changes shape: `score: 9` and `score: 148` are not the
  /// same number of pixels wide, and the hint line comes and goes with the run
  /// state. A guessed constant is either padded out with dead space or one
  /// character too narrow — and the too-narrow version puts the end of a line
  /// back on top of a pipe, which is the exact problem the backing exists to
  /// prevent.
  ///
  /// The early return is because this is called on every frame and the text
  /// changes only when the score or the state does. Re-laying-out a paragraph
  /// sixty times a second to arrive at the same pixels is work nobody sees.
  set text(String value) {
    if (_readout.text != value) {
      _readout.text = value;
      size.setValues(
        _readout.size.x + _padding * 2,
        _readout.size.y + _padding * 2,
      );
    }
  }

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    await add(_readout);
  }

  @override
  void render(Canvas canvas) {
    final RRect scoreRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.x, size.y),
      const Radius.circular(10),
    );
    canvas.drawRRect(scoreRect.shift(const Offset(0, 4)), _cardBorder);
    canvas.drawRRect(scoreRect, _backing);
  }
}
