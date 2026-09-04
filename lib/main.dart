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
// PREFIXED, and it has to be: `package:flame/game.dart` exports a Flame
// `Timer` of its own — a game-loop countdown, not a scheduler — and the two
// names collide at this import. The prefix says which one is meant instead of
// leaving it to whichever import happens to be listed last.
import 'dart:async' as async show Timer;
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/scheduler.dart' show FrameTiming, SchedulerBinding;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:flappymiata/game/course_seed.dart';
import 'package:flappymiata/game/game_model.dart';
import 'package:flappymiata/game/replay.dart';
import 'package:flappymiata/game/run_code.dart';
import 'package:flappymiata/ui/assist.dart';
import 'package:flappymiata/ui/game_screens.dart';
import 'package:flappymiata/ui/high_score_store.dart';
import 'package:flappymiata/ui/motion.dart';
import 'package:flappymiata/ui/palette.dart' as palette;

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
// The dev harness that used to live in `lib/dev/` — deleted once this file
// superseded it — hit exactly this: it painted the world onto the canvas AFTER
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

/// The flap-window highlight. Above the pipes, because a line hidden behind the
/// thing it is about is no help; below both cars, because an advisory overlay
/// must never be the reason a player cannot see where their car is.
const int _assistPriority = 15;

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

/// Lets the game play itself, so a frame-time measurement measures the game
/// being PLAYED rather than the game sitting on a menu.
///
/// ============================================================================
/// WHY A MEASUREMENT NEEDS THIS AND A METRONOME WILL NOT DO
/// ============================================================================
///
/// "Is the frame time good" is answered by running the game for a minute and
/// reading the frame histogram off the device. That only means something if the
/// minute was spent doing the expensive thing. The expensive frames here are
/// the ones with obstacles on screen, a ghost being replayed beside the live
/// car, and a score that keeps re-laying-out — i.e. the frames of an ACTUAL
/// RUN.
///
/// Tapping on a fixed cadence does not produce those. The difficulty ramp moves
/// the scroll speed and the gap height as the score climbs, and a fixed cadence
/// was tuned against neither: `tool/solver_bot.dart` records that the stock
/// `holdAltitude` policy now scores ZERO on the shipped course — it dies on the
/// first obstacle. A minute of that is a minute of the game-over screen, and
/// the histogram it produces is a histogram of a static card.
///
/// So the autopilot drives with the SAME policy `tool/solver_bot.dart` uses:
/// the assist solver's own surviving-state search, coasting while coasting is
/// survivable and tapping on the frame it stops being. That bot plays properly,
/// so the minute is spent on the frames that cost something.
///
/// ============================================================================
/// WHY IT IS FREE IN A NORMAL BUILD
/// ============================================================================
///
/// `bool.fromEnvironment` with no `--dart-define` is a CONST false, so every
/// `if (kAutopilot)` below is a branch the AOT compiler proves unreachable and
/// drops, along with everything only that branch reaches. Same mechanism as
/// [kShowCollisionBoxes] above. The measured cost of the whole feature in a
/// shipped APK is zero bytes, and that is checked by building both ways and
/// comparing — not by trusting this paragraph.
///
/// Build the instrumented APK with:
///
///     flutter build apk --release --dart-define=AUTOPILOT=true
///
/// WHAT IT PINS, AND WHY EACH ONE: a measurement has to be the same measurement
/// twice, so the two sources of run-to-run variation are nailed down. The
/// course is forced to [classicCourseSeed] instead of today's date, so the run
/// does not change at midnight or between two machines in different time zones.
/// The high-score store is put in memory, so a ghost left on the device by an
/// earlier run cannot add a second car to the screen in one measurement and not
/// the other.
const bool kAutopilot = bool.fromEnvironment('AUTOPILOT');

void main() {
  // Both statements are inside a `kAutopilot` branch the compiler removes from
  // a normal build, so `main` in a shipped APK is the single `runApp` it has
  // always been.
  if (kAutopilot) {
    // The binding has to exist before a timings callback can be attached, and
    // `runApp` would not have created it yet. Idempotent — `runApp` calls the
    // same thing and gets the instance already made.
    WidgetsFlutterBinding.ensureInitialized();
    final FrameTimingProbe probe = FrameTimingProbe()..start();

    // Reported on a wall-clock timer rather than on a frame count, because the
    // whole question is whether frames are arriving on time: a counter driven
    // by frames would stretch its own reporting interval by exactly the amount
    // of lateness it exists to measure, and a run that stalled would go quiet
    // instead of shouting.
    int elapsed = 0;
    async.Timer.periodic(const Duration(seconds: 5), (async.Timer _) {
      elapsed += 5;
      probe.report('t=${elapsed}s');
    });
  }
  runApp(const FlappyMiataApp());
}

/// THIS WIDGET IS DELIBERATELY THIN.
///
/// `lib/main.dart` is the one file both people in this repo have to touch, so
/// every line here is a line that can collide on merge. Its job is wiring only:
/// start the app, hand Flutter a game. Input and drawing live on the game
/// below; gameplay lives in `lib/game/`; screens and menus belong in `lib/ui/`,
/// where one person can own a file outright.
///
/// WHY IT IS A `StatefulWidget` AND NO LONGER A `GameWidget.controlled`:
/// `.controlled` builds the game from a factory and never hands the instance
/// back, and the accessibility bridge below needs the instance — it reads the
/// platform's "reduce motion" switch out of the `MediaQuery` and pushes it into
/// the game. Creating the game once in a field initialiser gives exactly the
/// guarantee `.controlled` was here for: a `State` outlives a rebuild, so a
/// rebuild cannot construct a second game and throw away the run in progress.
class FlappyMiataApp extends StatefulWidget {
  const FlappyMiataApp({super.key});

  @override
  State<FlappyMiataApp> createState() => _FlappyMiataAppState();
}

class _FlappyMiataAppState extends State<FlappyMiataApp> {
  /// `late final` on a field, so the game is built on the first build and never
  /// again.
  late final FlappyMiataGame _game = FlappyMiataGame();

  @override
  Widget build(BuildContext context) {
    // The bridge is the ONLY place the operating system's accessibility
    // settings enter this app. See `lib/ui/motion.dart` for why it has to be a
    // widget: `MediaQuery` needs a `BuildContext`, a `FlameGame` has none, and
    // the setting can change while the app is open.
    return SystemMotionBridge(
      host: _game,
      child: GameWidget<FlappyMiataGame>(game: _game),
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
    implements GameScreenHost, MotionHost {
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
    : // An explicit argument always wins — the tests pass both, and the
      // autopilot must not be able to overrule a caller that said what it
      // wanted. Only the DEFAULTS change under [kAutopilot], and both of them
      // change for the same reason: a frame-time measurement has to be
      // repeatable, so neither the calendar nor whatever is left in the
      // device's preferences may decide what gets drawn.
      courseSeed =
          courseSeed ?? (kAutopilot ? classicCourseSeed : todaysCourseSeed()),
      highScoreStore = highScoreStore ??
          (kAutopilot
              ? InMemoryHighScoreStore()
              : SharedPreferencesHighScoreStore());

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

  /// Whether the run currently on screen beat the record.
  ///
  /// LATCHED, not recomputed. [_captureFinishedRun] runs on every frame after a
  /// run ends, and by its second pass `_bestScore` already IS this run's score —
  /// so anything derived at that point would say "no" about the run that had
  /// just said "yes", and the card would flash NEW BEST for exactly one frame.
  /// It is written once, inside the branch that stores the new best, and reset
  /// by [_startRun].
  ///
  /// STRICTLY BETTER, not "at least as good". A run that ties the record did not
  /// set it, and a first run that scores nothing sets a best of 0 without
  /// beating anything — which is the bug this replaced. `_bestScore` starts at
  /// 0, so `score > _bestScore` is false for that run and true for any run that
  /// actually got somewhere, with no special case for the first run of a
  /// session.
  bool _isNewBest = false;

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

  /// What the player has asked for about decorative motion. Follows the
  /// platform by default. See `lib/ui/motion.dart`.
  MotionSetting _motionSetting = MotionSetting.system;

  /// What the platform's own accessibility switch says, as last reported by
  /// [SystemMotionBridge]. False until the bridge has been built, which is the
  /// right default: a game with no widget tree over it — a headless test — has
  /// no platform to ask.
  bool _systemDisablesAnimations = false;

  /// The decorative clock the backdrop's parallax is drawn from.
  ///
  /// SEPARATE FROM THE RUN'S CLOCK, and that separation is the feature. It
  /// takes raw wall-clock seconds, it is read by nothing but [_BackdropLayer],
  /// and there is no path from it into `_run` — which is what makes "reduced
  /// motion changes no run" true by construction rather than by care.
  final DecorClock _decor = DecorClock();

  /// The assist solver, or null when assist mode is off — which is the default,
  /// and is also what "off" MEANS here. See [toggleAssist].
  AssistSolver? _assist;

  /// The current backward pass, reused for about a second. Rebuilt when it stops
  /// covering the frame the run is on, and thrown away on a restart.
  AssistPlan? _assistPlan;

  /// The bot that plays the game while a measurement is running, or null in
  /// every normal build.
  ///
  /// SEPARATE FROM [_assist], and it has to be. Assist mode is a thing the
  /// player switches on to be SHOWN where to go; this is a thing that DRIVES.
  /// They happen to consult the same solver, but sharing one would mean the
  /// measurement could not be taken with the highlight off, and turning the
  /// highlight off mid-measurement would silently stop the car.
  ///
  /// Built eagerly rather than lazily because [kAutopilot] is a compile-time
  /// constant: when it is false this initialiser is a branch the compiler
  /// discards, and with it every reference to [Autopilot].
  final Autopilot? _autopilot = kAutopilot ? Autopilot() : null;

  /// What to draw this frame, or null when there is nothing to say.
  ///
  /// RECOMPUTED IN `update`, NOT IN `render`. A `render` that computed anything
  /// would be doing it on whatever schedule the device felt like painting at,
  /// and the advice is about the frame the MODEL is on. Working it out beside
  /// the step that produced that frame keeps the two in step by construction.
  AssistAdvice? _advice;

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

  /// This frame's flap-window advice, or null when assist mode is off or has
  /// nothing to say. Read-only, for the layer that draws it.
  AssistAdvice? get advice => _advice;

  /// Seconds of decoration elapsed, for the backdrop to draw its parallax from.
  /// Frozen while motion is reduced.
  double get decorPhase => _decor.phase;

  /// Whether decorative motion is currently stopped.
  bool get reduceMotion => shouldReduceMotion(
        setting: _motionSetting,
        systemDisablesAnimations: _systemDisablesAnimations,
      );

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
  int get riskScore => _run.model.riskScore;

  @override
  int get bestScore => _bestScore;

  @override
  bool get hasBestScore => _hasBestScore;

  @override
  bool get isNewBest => _isNewBest;

  @override
  bool get paused => _paused;

  @override
  bool get assistEnabled => _assist != null;

  @override
  MotionSetting get motionSetting => _motionSetting;

  @override
  bool get systemDisablesAnimations => _systemDisablesAnimations;

  /// Told by [SystemMotionBridge] whenever the platform's switch changes.
  ///
  /// Guarded on a real change, because `didChangeDependencies` fires for any
  /// inherited widget the bridge depends on — a rotation moves the
  /// `MediaQuery` — and bumping [revision] on every one of those would rebuild
  /// the screens for nothing.
  @override
  set systemDisablesAnimations(bool value) {
    if (_systemDisablesAnimations == value) return;
    _systemDisablesAnimations = value;
    _revision.value++;
  }

  /// Steps the motion setting on. Touches no rule and no run — see
  /// [GameScreenHost.cycleMotion].
  @override
  void cycleMotion() {
    _motionSetting = nextMotionSetting(_motionSetting);
    _revision.value++;
  }

  /// Turns the flap-window highlight on and off.
  ///
  /// SWITCHING IT ON ALLOCATES, switching it off releases. The solver's bitmaps
  /// are about a megabyte and a half, and a player who never turns assist on
  /// should not be carrying them — which is also why the null-ness of [_assist]
  /// IS the setting, rather than a bool beside an always-present solver that
  /// could disagree with it.
  ///
  /// Nothing about the run is touched. There is no `_run` here, no `tick`, and
  /// nothing queued: the model cannot tell this happened, which is the property
  /// `test/assist_test.dart` asserts.
  @override
  void toggleAssist() {
    if (_assist == null) {
      _assist = AssistSolver();
    } else {
      _assist = null;
      _assistPlan = null;
      _advice = null;
    }
    _syncScreens();
    _revision.value++;
  }

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
  Color backgroundColor() => const Color(palette.gameBackground);

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
      _AssistLayer(),
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

    // AND THE CLAIM HAS TO BE RE-EXAMINED, because the record it was made
    // against has just changed underneath it. The window is small — the store
    // has to answer AFTER a whole run has been played and lost — but it is the
    // same defect the `>=` on the game-over card was: a run that beat nothing
    // saying it beat something. Here the run really did beat the best KNOWN at
    // the time, and then an older, better record turned up. It did not set the
    // record after all.
    // Compared against the STORED score rather than against `_bestScore`, which
    // this run may itself have just set: `score <= _bestScore` is true for every
    // record-setting run and would withdraw every claim there is.
    if (_isNewBest && stored.score >= _run.model.score) {
      _isNewBest = false;
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

    // The new run has beaten nothing yet. Cleared here rather than when the run
    // ENDS, so the game-over card can go on reporting the run it is describing
    // for as long as it is up.
    _isNewBest = false;

    // A pass is anchored to a frame number and a y of the run it was built for.
    // The new run starts at frame 0 again, so the old pass would be read as
    // advice about a moment that has not happened yet.
    _assistPlan = null;
    _advice = null;
    _autopilot?.reset();

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
        // THE BOT'S TAP LANDS EXACTLY WHERE A PLAYER'S WOULD. `tap()` queues,
        // and the queued tap is spent by the very next `step()` before that
        // frame's physics — so deciding here, immediately above the step, gives
        // the bot the same `flap-then-tick` frame that `tool/headless_sim.dart`
        // hands its policies and that the fairness prover searches over. A
        // decision taken anywhere else in this method would be a decision about
        // a different frame, and the bot would be measuring a game the tests
        // have never checked.
        //
        // Dropped entirely from a normal build: `_autopilot` is initialised
        // from a const false, so the compiler knows this is dead.
        if (_autopilot != null && _autopilot.wantsTap(_run.model, _run.frame)) {
          _run.tap();
        }

        _run.step();

        // The ghost only moves once the live run has actually started. Until the
        // first tap the live car is frozen on the start line, and a ghost that
        // set off without it would be racing nobody.
        if (_run.model.state != RunState.ready) {
          _ghost?.step();
        }
      }

      _captureFinishedRun();

      // A measurement must not spend its last forty seconds on the game-over
      // card. Restarting the moment the run ends keeps the minute full of the
      // frames worth measuring — and it deliberately keeps the EXPENSIVE ones,
      // because a restart allocates a fresh recorder and a fresh ghost player,
      // which is the heaviest single frame the game ever has. Hiding that from
      // the histogram would be measuring a kinder game than the one that ships.
      if (_autopilot != null && _run.finished) {
        _startRun();
      }
      _updateAssist();

      // The decoration's own clock. Inside the `!_paused` branch with
      // everything else, because a stopped world whose hills kept sliding would
      // be a paused game that still looked like it was moving. `reduceMotion`
      // is asked here, once per frame, rather than cached: the platform switch
      // can change under a running game.
      _decor.advance(dt, reduced: reduceMotion);
    }

    _panel.text = _hudText;
    _syncScreens();
  }

  /// Refreshes the flap-window advice for the frame the run has just reached.
  ///
  /// READ-ONLY ON THE RUN. Everything here takes `_run.model` and `_run.frame`
  /// as arguments and returns numbers; nothing assigns to `_run`, calls `tap`,
  /// or steps anything. That is the whole reason assist mode cannot change a
  /// run, and it is why this method is the only place in the file that touches
  /// the solver.
  void _updateAssist() {
    final AssistSolver? solver = _assist;
    if (solver == null) {
      _advice = null;
      return;
    }
    final GameModel model = _run.model;
    final int frame = _run.frame;

    // Nothing to advise before the first tap or after the crash. Without this
    // the last live pass would go on covering the frozen frame number and the
    // highlight would hang over a wreck, describing a future the car does not
    // have.
    if (model.state != RunState.playing) {
      _advice = null;
      return;
    }

    // A pass covers about a second and is not invalidated by anything the
    // player does — see `lib/ui/assist.dart` on why the surviving-state sets
    // belong to the world rather than to the car. So this rebuilds roughly once
    // per second, not once per frame.
    AssistPlan? plan = _assistPlan;
    if (plan == null || !plan.isCurrent || !plan.covers(frame)) {
      plan = solver.plan(model, frame);
      _assistPlan = plan;
    }
    _advice = plan?.adviseAt(model, frame);
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
      // Computed BEFORE `_bestScore` moves, because afterwards the two are
      // equal and the question can no longer be asked. This is the only place
      // in the program that knows what the record was a moment ago.
      _isNewBest = score > _bestScore;
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
    // On its own line and never summed with the score above it. Two numbers,
    // two questions: how far, and how close. See `lib/game/risk_score.dart`.
    final String risk = 'risk: ${_run.model.riskScore}';
    return _hasBestScore
        ? '$score\n$risk\nbest: $_bestScore'
        : '$score\n$risk';
  }
}

/// Collects the engine's own frame timings and prints them where `adb logcat`
/// can read them.
///
/// ============================================================================
/// WHY THIS EXISTS WHEN `adb shell dumpsys gfxinfo` ALREADY REPORTS JANK
/// ============================================================================
///
/// It reports jank for the ANDROID VIEW HIERARCHY, drawn by HWUI. A Flutter app
/// in its default render mode does not draw there. It is handed a
/// `SurfaceView` — visible in `dumpsys SurfaceFlinger --list` as
/// `SurfaceView[com.allen.flappymiata/...](BLAST)` — and the engine's raster
/// thread paints straight into that surface's buffers, bypassing HWUI
/// completely.
///
/// The consequence, measured on this app rather than assumed: after the game
/// had been playing for minutes, `dumpsys gfxinfo com.allen.flappymiata`
/// reported `Total frames rendered: 1`. That one frame is the Android view that
/// HOLDS the surface being laid out once. Every frame of the actual game is
/// invisible to it.
///
/// So the honest reading of a "0% janky" from gfxinfo on this app is not "the
/// game is smooth" — it is "gfxinfo did not see the game". A measurement whose
/// instrument cannot observe the thing being measured returns the same answer
/// whatever the answer should have been, and that is worse than no measurement,
/// because it looks like one.
///
/// ============================================================================
/// WHAT IS MEASURED INSTEAD
/// ============================================================================
///
/// `SchedulerBinding.addTimingsCallback` is the engine's own report, one record
/// per frame the engine actually presented. [FrameTiming.totalSpan] is the
/// whole span from the vsync that started the frame to the moment the raster
/// thread finished it — i.e. the number that has to fit inside the display's
/// frame budget or the viewer sees a stutter. That is the number binned below,
/// and `buildDuration` and `rasterDuration` are kept beside it so a slow frame
/// can be blamed on the right thread.
///
/// Dropped from a normal build by the same const-false mechanism as everything
/// else here: building with and without `--dart-define=AUTOPILOT=true` produced
/// `libapp.so` files of identical size on two of the three ABIs.
class FrameTimingProbe {
  /// The display's frame budget in microseconds.
  ///
  /// 60 Hz is asserted rather than assumed — [start] reads the real refresh
  /// rate off the view and complains in the log if it is not what this says, so
  /// a run on a 90 or 120 Hz panel cannot be scored against the wrong deadline
  /// in silence.
  static const int budgetMicros = 16667;

  /// One bucket per millisecond up to [_buckets] − 1, and everything slower in
  /// the last one. Milliseconds, because that is the unit a frame budget is
  /// argued about in.
  static const int _buckets = 64;

  final List<int> _total = List<int>.filled(_buckets, 0);
  final List<int> _build = List<int>.filled(_buckets, 0);
  final List<int> _raster = List<int>.filled(_buckets, 0);

  /// `buildDuration + rasterDuration` — the WORK a frame cost, as opposed to
  /// the wall-clock span it occupied.
  ///
  /// WHY BOTH THIS AND [_total] ARE KEPT, because the difference between them
  /// is the whole trap in this measurement: [FrameTiming.totalSpan] runs from
  /// the vsync that scheduled the frame to the instant the raster thread
  /// finished it, and those two threads are PIPELINED — frame n+1 is being
  /// built while frame n is still being rasterised. So a totalSpan of 20 ms is
  /// entirely normal on a renderer that is comfortably holding 60 fps, and
  /// scoring it against a 16.667 ms budget reports a 100% failure for a game
  /// nobody would call janky. This histogram is the number that has to fit.
  final List<int> _work = List<int>.filled(_buckets, 0);

  /// Gaps between the vsyncs consecutive frames were scheduled against, in
  /// whole frame intervals: 1 means the frame arrived on the very next vsync,
  /// 2 means one vsync went by with nothing new to show.
  ///
  /// THIS IS THE HONEST JANK SIGNAL. What a player sees is not how long a frame
  /// took, it is whether the picture changed when the display refreshed. A
  /// repeated vsync is a stutter and nothing else is.
  final List<int> _gaps = List<int>.filled(_buckets, 0);

  int _frames = 0;
  int _over = 0;
  int _worstMicros = 0;

  /// Vsync intervals that came and went with no new frame — the count Bar 5's
  /// "zero jank frames" is really asking about.
  int _missedVsyncs = 0;

  /// The vsync of the previous frame, or -1 before there has been one. The
  /// first frame has no predecessor and therefore contributes no interval;
  /// counting it as a gap of one would invent a frame that was never presented.
  int _lastVsync = -1;

  /// Begins collecting, and states the deadline it is going to score against.
  ///
  /// The refresh rate is READ, not assumed. A jank count is a comparison
  /// against a budget, so a run on a 90 Hz or 120 Hz panel scored against
  /// 16.667 ms would report a clean sheet while missing a third of its frames —
  /// and it would report it in exactly the same words as a real pass. Printing
  /// both numbers means the log carries the evidence that the comparison was
  /// the right one, rather than the reader having to take it on faith.
  void start() {
    final ui.FlutterView? view =
        SchedulerBinding.instance.platformDispatcher.implicitView;
    final double hz = view?.display.refreshRate ?? 0;
    final int measuredBudget = hz > 0 ? (1000000 / hz).round() : 0;
    debugPrint(
      'FRAMEPROBE display refreshRate=${hz.toStringAsFixed(2)}Hz '
      'measuredBudgetUs=$measuredBudget assumedBudgetUs=$budgetMicros '
      '${measuredBudget != 0 && (measuredBudget - budgetMicros).abs() > 500 ? "MISMATCH — the jank count below is scored against the assumed budget, not this display" : "ok"}',
    );
    SchedulerBinding.instance.addTimingsCallback(_record);
  }

  void _record(List<FrameTiming> timings) {
    for (final FrameTiming t in timings) {
      final int total = t.totalSpan.inMicroseconds;
      _frames++;
      if (total > budgetMicros) _over++;
      if (total > _worstMicros) _worstMicros = total;
      _bump(_total, total);
      _bump(_build, t.buildDuration.inMicroseconds);
      _bump(_raster, t.rasterDuration.inMicroseconds);
      _bump(
        _work,
        t.buildDuration.inMicroseconds + t.rasterDuration.inMicroseconds,
      );

      final int vsync = t.timestampInMicroseconds(ui.FramePhase.vsyncStart);
      if (_lastVsync >= 0) {
        // Rounded rather than floored: vsync timestamps carry a little jitter,
        // so a perfectly consecutive pair can measure 16.4 or 16.9 ms and a
        // floor would score half of a healthy run as a skipped interval.
        final int intervals =
            ((vsync - _lastVsync) / budgetMicros).round().clamp(1, _buckets - 1);
        _gaps[intervals]++;
        _missedVsyncs += intervals - 1;
      }
      _lastVsync = vsync;
    }
  }

  void _bump(List<int> hist, int micros) {
    // Floor to whole milliseconds. A frame of 16.9 ms lands in bucket 16, so
    // "bucket 16 and below" is NOT the same as "inside the 16.667 ms budget" —
    // which is exactly why [_over] is counted against the microsecond value and
    // never read off this histogram.
    final int ms = micros ~/ 1000;
    hist[ms >= _buckets ? _buckets - 1 : ms]++;
  }

  /// Prints everything collected so far as one line per histogram.
  ///
  /// Tagged so `adb logcat -s flutter | findstr FRAMEPROBE` finds it, and
  /// printed as counts rather than as a verdict: the raw distribution is the
  /// deliverable, and a reader who disagrees with the jank threshold can
  /// re-derive their own from these numbers.
  void report(String label) {
    final StringBuffer out = StringBuffer()
      ..write('FRAMEPROBE $label frames=$_frames ')
      ..write('missedVsyncs=$_missedVsyncs ')
      ..write('spanOverBudget=$_over ')
      ..write('budgetUs=$budgetMicros ')
      ..write('worstSpanUs=$_worstMicros');
    debugPrint(out.toString());
    debugPrint('FRAMEPROBE $label gapsInVsyncs=${_dense(_gaps)}');
    debugPrint('FRAMEPROBE $label workMs=${_dense(_work)}');
    debugPrint('FRAMEPROBE $label totalSpanMs=${_dense(_total)}');
    debugPrint('FRAMEPROBE $label buildMs=${_dense(_build)}');
    debugPrint('FRAMEPROBE $label rasterMs=${_dense(_raster)}');
  }

  /// The non-empty buckets only, as `ms:count` pairs. A 64-entry line of mostly
  /// zeroes is a line nobody reads.
  String _dense(List<int> hist) {
    final List<String> parts = <String>[];
    for (int i = 0; i < hist.length; i++) {
      if (hist[i] != 0) parts.add('$i:${hist[i]}');
    }
    return parts.join(' ');
  }
}

/// The bot that plays the game during a frame-time measurement.
///
/// ============================================================================
/// THIS IS THE SAME POLICY AS `tool/solver_bot.dart`, AND THAT IS DELIBERATE
/// ============================================================================
///
/// The decision below is a line-for-line restatement of `solverPolicy` in
/// `tool/solver_bot.dart`. It is a second copy rather than a call, for one
/// reason worth stating plainly: `tool/` is not on the app's import path — it
/// is a directory of `dart run` scripts and test helpers — and putting it there
/// would mean shipping the whole tool directory into the APK to run a bot that
/// no shipped build can reach.
///
/// A second copy is a second chance to drift, so the drift is made visible
/// rather than trusted: the group `Autopilot matches tool/solver_bot.dart` in
/// `test/assist_test.dart` drives BOTH this class and `solverPolicy` over the
/// same run and requires them to make the same decision on every frame. If
/// somebody improves one and not the other, that test says so, and it says so
/// about the frame they first disagreed on.
///
/// ============================================================================
/// WHAT THE POLICY IS
/// ============================================================================
///
/// `lib/ui/assist.dart` computes, for a bounded horizon, the exact SET of states
/// from which some continuation survives. The whole policy is then:
///
///   * while coasting keeps the car inside that set, coast;
///   * on the frame coasting would leave it, tap.
///
/// Within one horizon that cannot die, because leaving the set is the
/// definition of having no future. Across horizons it can — a pass looks a
/// bounded distance ahead — which is why the game restarts the bot rather than
/// assuming it plays forever. Full argument in `tool/solver_bot.dart`.
class Autopilot {
  /// The search. Allocated once and reused: a pass covers about a second of
  /// play, so this rebuilds roughly once per second rather than once per frame.
  final AssistSolver _search = AssistSolver();

  /// The pass currently being read, or null before the first one.
  AssistPlan? _plan;

  /// Thrown away when a run restarts.
  ///
  /// Not strictly required — a pass is anchored to a frame number and
  /// `covers()` already rejects the frame 0 of a new run — but a cache that is
  /// cleared where the thing it describes is replaced needs no argument about
  /// why it is safe to keep.
  void reset() {
    _plan = null;
  }

  /// Whether the bot taps on the frame [model] is about to be stepped through.
  bool wantsTap(GameModel model, int frame) {
    // The first tap. A `ready` model does not move at all — `tick` returns the
    // receiver — so nothing can be planned about it until the run has begun.
    if (model.state == RunState.ready) return true;
    if (model.state == RunState.dead) return false;

    AssistPlan? plan = _plan;
    if (plan == null || !plan.isCurrent || !plan.covers(frame)) {
      plan = _search.plan(model, frame);
      _plan = plan;
    }
    final AssistAdvice? advice = plan?.adviseAt(model, frame);

    // No pass could be built — no obstacle ahead, or a state the search cannot
    // represent. Coasting is the honest answer; inventing a tap here would be
    // exactly the guess this bot exists to avoid.
    if (advice == null) return false;

    // Doing nothing still leaves a future, so do nothing. This is the branch
    // that runs on almost every frame.
    if (advice.latestSafeCoast >= 1) return false;

    // Coasting one more frame leaves the surviving set, so this is the frame to
    // tap on — if tapping is still one of the moves that survives. When it is
    // not the car is already lost inside this horizon and the tap changes
    // nothing; it is still made, because a doomed car flying is better viewing
    // than a doomed car falling, and nothing downstream reads it either way.
    return advice.flapNow || advice.doomed;
  }
}

/// The sky, the hills, the clouds and the ground: everything behind the game.
///
/// ============================================================================
/// THE ONLY THING IN THIS GAME THAT MOVES FOR DECORATION
/// ============================================================================
///
/// The hills slide and the clouds drift, both far slower than the pipes.
/// Parallax is depth stated as a speed ratio and nothing else, which is why
/// `lib/ui/motion.dart` expresses it as two numbers rather than as two layers
/// of art.
///
/// It is also the whole of what reduced motion switches off. That is a
/// deliberately small claim and it is worth being precise about, because the
/// mistake it is guarding against is a big one: everything ELSE that moves here
/// is information. The pipes are the course. The car is the player. The ghost
/// is the record being raced. The assist path is where the car is going.
/// Stopping any of those would not be reducing motion, it would be taking the
/// game away from the player who asked for less motion — which is exactly the
/// "accessible mode is an easy mode" failure, and the reason
/// `test/reduced_motion_test.dart` replays a whole run both ways and demands
/// the two be identical frame for frame.
///
/// The parallax reads [FlappyMiataGame.decorPhase], which stops advancing when
/// motion is reduced. There is no second switch and no per-layer flag: one
/// clock, and everything decorative is drawn from it.
class _BackdropLayer extends Component with HasGameReference<FlappyMiataGame> {
  _BackdropLayer() : super(priority: -100);

  static final Paint _sky = Paint()
    ..shader = ui.Gradient.linear(
      const Offset(0, 0),
      const Offset(0, 900),
      const <Color>[Color(palette.skyTop), Color(palette.skyBottom)],
    );
  static final Paint _horizon =
      Paint()..color = const Color(palette.horizonBand);
  static final Paint _hill = Paint()..color = const Color(palette.hill);
  static final Paint _cloud = Paint()..color = const Color(palette.cloud);
  static final Paint _ground = Paint()..color = const Color(palette.ground);

  // ---------------------------------------------------------------------------
  // WHERE THE GROUND STARTS. Three shapes have to agree about this or the
  // backdrop grows a seam: the sky stops here, the horizon band starts here,
  // and the hills close their silhouette on this line. It used to be the
  // literal `0.70` written out in four places, which is three chances for one
  // of them to be edited alone.
  //
  // Fractions of the screen HEIGHT, like everything else this game draws, so a
  // rotation or a different device changes no arithmetic.
  // ---------------------------------------------------------------------------

  /// The horizon: the bottom of the sky and the top of the grey band.
  static const double _horizonY = 0.70;

  /// The top of the ground, and the bottom of the grey band.
  static const double _groundY = 0.76;

  /// The hill silhouette, kept between frames.
  ///
  /// REBUILT ONLY WHEN THE SCREEN CHANGES SIZE. A `Path` is not free: building
  /// one allocates, and handing a fresh object to the rasteriser every frame
  /// throws away whatever it had already worked out about the last one. The
  /// shape here is a function of the screen size and nothing else — it does not
  /// depend on the parallax, which is applied as a canvas TRANSLATION rather
  /// than by moving the points — so on a phone that is not being rotated this
  /// is built once for the life of the process instead of a hundred and twenty
  /// times a second (twice per frame, once per tiled copy).
  Path? _hills;
  Size? _hillsFor;

  @override
  void render(Canvas canvas) {
    final Size size = game.size.toSize();

    // ONLY DOWN TO THE HORIZON, not the whole screen.
    //
    // Everything below [_horizonY] is covered by two fully opaque rectangles —
    // the band and the ground, both `0xFF` in `lib/ui/palette.dart` — so the
    // gradient that used to be painted down there was never visible in a single
    // frame. On a device with a real GPU that waste is invisible; on the
    // software rasteriser in the emulator this is measured on, a full-screen
    // GRADIENT fill is the most expensive single operation in the frame, and
    // 30% of it was being thrown away.
    //
    // The picture is unchanged, and it is unchanged for a reason worth stating:
    // the shader is anchored to absolute pixels 0..900 rather than to the
    // rectangle it fills, so shrinking the rectangle moves no colour. It only
    // stops painting pixels that something opaque was about to cover.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height * _horizonY),
      _sky,
    );

    // How far each layer has slid, as a fraction of one screen width in [0, 1).
    // Frozen at whatever it was when motion was last reduced.
    final double phase = game.decorPhase;
    final double hillShift =
        parallaxOffset(phase, hillDriftPerSecond) * size.width;
    final double cloudShift =
        parallaxOffset(phase, cloudDriftPerSecond) * size.width;

    // EACH LAYER IS DRAWN TWICE, ONE WIDTH APART, and the pair is slid left by
    // strictly less than a width. So the seam between the two copies is always
    // off the right-hand edge, and the layer repeats forever without any
    // wrapping arithmetic per shape. The hill path's first and last points are
    // both at the horizon, so where one copy ends the next begins at the same
    // height and the join is invisible.
    _tile(canvas, size, hillShift, _drawHills);
    _tile(canvas, size, cloudShift, _drawClouds);

    canvas.drawRect(
      Rect.fromLTWH(
        0,
        size.height * _horizonY,
        size.width,
        size.height * (_groundY - _horizonY),
      ),
      _horizon,
    );
    canvas.drawRect(
      Rect.fromLTWH(
        0,
        size.height * _groundY,
        size.width,
        size.height * (1 - _groundY),
      ),
      _ground,
    );
  }

  /// Draws [paint] twice, a screen width apart, shifted left by [shift].
  void _tile(
    Canvas canvas,
    Size size,
    double shift,
    void Function(Canvas, Size) paint,
  ) {
    canvas.save();
    canvas.translate(-shift, 0);
    paint(canvas, size);
    canvas.translate(size.width, 0);
    paint(canvas, size);
    canvas.restore();
  }

  void _drawHills(Canvas canvas, Size size) {
    canvas.drawPath(_hillPath(size), _hill);
  }

  /// The hill silhouette at [size], built on the first call and on any resize.
  ///
  /// The first and last points are both on the horizon, which is what makes the
  /// two tiled copies join invisibly — where one ends the next begins at the
  /// same height.
  Path _hillPath(Size size) {
    final Path? cached = _hills;
    if (cached != null && _hillsFor == size) return cached;
    final Path hills = Path()
      ..moveTo(0, size.height * _horizonY)
      ..lineTo(size.width * 0.16, size.height * 0.57)
      ..lineTo(size.width * 0.31, size.height * _horizonY)
      ..lineTo(size.width * 0.49, size.height * 0.53)
      ..lineTo(size.width * 0.68, size.height * _horizonY)
      ..lineTo(size.width * 0.84, size.height * 0.59)
      ..lineTo(size.width, size.height * _horizonY)
      ..close();
    _hills = hills;
    _hillsFor = size;
    return hills;
  }

  void _drawClouds(Canvas canvas, Size size) {
    _drawCloud(canvas, Offset(size.width * 0.20, size.height * 0.18), 0.9);
    _drawCloud(canvas, Offset(size.width * 0.76, size.height * 0.29), 0.65);
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

/// Everything that scrolls: both pipes of every obstacle. Sits at
/// [_worldPriority], i.e. underneath the score.
///
/// ONE component for the whole world rather than one component per obstacle,
/// because `tick` rebuilds the obstacle list from scratch every frame. The
/// model already owns those objects; mirroring them into a component tree would
/// mean adding and removing components sixty times a second in order to display
/// data that is already sitting in a field.
///
/// THE PIPES KEPT THEIR GREEN when the scenery behind them did not. They are
/// the thing the player must not hit, so where a green and a green had to be
/// pulled apart for a deuteranope, the obstacle stayed put and the background
/// moved. See `lib/ui/palette.dart`.
class _WorldLayer extends Component with HasGameReference<FlappyMiataGame> {
  _WorldLayer() : super(priority: _worldPriority);

  static const double _pipeCapHeight = 44.0;

  static final Paint _pipeOutline =
      Paint()..color = const Color(palette.pipeOutline);
  static final Paint _pipeBody = Paint()..color = const Color(palette.pipeBody);
  static final Paint _pipeHighlight =
      Paint()..color = const Color(palette.pipeHighlight);
  static final Paint _pipeShadow =
      Paint()..color = const Color(palette.pipeShadow);

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
        const ColorFilter.mode(Color(palette.ghostSilhouette), BlendMode.srcIn)
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

/// The flap-window highlight: where the car is going, and when a tap is on
/// offer.
///
/// ============================================================================
/// WHY THE PATH IS DRAWN GOING RIGHT WHEN THE CAR NEVER MOVES SIDEWAYS
/// ============================================================================
///
/// The car sits at a fixed x and the world comes to it, so the car's future
/// positions are all on one vertical line — a preview drawn there would be a
/// stack of dots on top of each other, saying nothing about WHEN.
///
/// So the path is drawn in the WORLD's frame instead: the point "in d frames"
/// goes at `carX + d * scroll * dt`, which is exactly where the car will be
/// relative to the pipes when that frame arrives. The curve therefore reaches
/// out toward the oncoming obstacle and lands on the gap it is going to hit,
/// which is the picture a player already has in their head.
///
/// The scroll speed is read once, for the current score, and the ramp may nudge
/// it within the preview. Over a second that is a fraction of a percent of x,
/// and it moves only where the curve is DRAWN, never what the solver decided —
/// so the highlight can be a hair's width out horizontally and cannot be wrong.
class _AssistLayer extends Component with HasGameReference<FlappyMiataGame> {
  _AssistLayer() : super(priority: _assistPriority);

  /// The coasting part of the path: where the car goes if nothing is tapped.
  ///
  /// AMBER, AND IT USED TO BE WHITE. Three signals are drawn on top of each
  /// other here — this path, the offered window, the deadline — and the two
  /// dichromacies this app is checked against both lose the red-green axis. So
  /// the three are spread along the axis that survives, blue to yellow, with
  /// teal at one end and amber at the other. White at 60% scored 2.14 ΔE₀₀
  /// against the window for a protanope, which is to say the two lines were the
  /// same line. See `lib/ui/palette.dart`.
  static final Paint _coast = Paint()
    ..color = const Color(palette.assistCoast)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;

  /// The offered window. Teal, like every other affordance in this game.
  static final Paint _window = Paint()
    ..color = const Color(palette.assistWindow)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 6;

  /// The last frame on which doing nothing is still survivable.
  ///
  /// The stroke widths above and below are not decoration either: colour is
  /// never the only thing separating these three, because a channel that some
  /// readers do not have cannot be the only channel. 2px, 6px and a
  /// cross-stroke say the same thing the hues do.
  static final Paint _deadline = Paint()
    ..color = const Color(palette.assistDeadline)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3;

  @override
  void render(Canvas canvas) {
    final AssistAdvice? advice = game.advice;
    if (advice == null || advice.path.length < 2) return;

    final Vector2 screen = game.size;
    final double step =
        Difficulty.scrollSpeedAt(game.model.score) * replayFrameSeconds;

    Offset at(int d) => Offset(
      (GameModel.carX + d * step) * screen.x,
      advice.path[d] * screen.y,
    );

    // The whole coast path first, thin, so the highlight has something to sit
    // on and the player can see where the car is headed even where no tap is
    // offered.
    for (int d = 0; d + 1 < advice.path.length; d++) {
      canvas.drawLine(at(d), at(d + 1), _coast);
    }

    // Then the offered frames, thick, drawn segment by segment rather than as
    // one span: the window is not guaranteed to be contiguous, and a single
    // start-to-end stroke would claim taps in any hole between.
    for (int d = 0; d + 1 < advice.path.length; d++) {
      if (advice.flapViable[d]) {
        canvas.drawLine(at(d), at(d + 1), _window);
      }
    }

    // And the deadline: a short cross-stroke at the last frame doing nothing is
    // survivable. Past this mark every continuation the search can represent is
    // dead, so it reads as "tap before here".
    final int last = advice.latestSafeCoast;
    if (last >= 0 && last < advice.path.length) {
      final Offset mark = at(last);
      canvas.drawLine(
        mark.translate(0, -GameModel.carHeight * screen.y),
        mark.translate(0, GameModel.carHeight * screen.y),
        _deadline,
      );
    }
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
    ..color = const Color(palette.debugCarBox)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;

  static final Paint _obstacleOutline = Paint()
    ..color = const Color(palette.debugObstacleBox)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;

  static final Paint _gapCentreLine = Paint()
    ..color = const Color(palette.debugGapCentre)
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
  ///
  /// IT WAS NOT `FF`. This comment said one thing and the constant beside it
  /// said `0xE8` — 91% — so 9% of whatever passed underneath was mixing into
  /// the colour the score was being read against, and the contrast of that pair
  /// was a property of the frame rather than of the palette. The car passes
  /// behind this panel too, not only the pipes: the car sits at x = 0.30 and is
  /// 0.16 wide, and the panel starts 16 logical pixels from the left edge.
  /// `test/palette_contrast_test.dart` now asserts the alpha rather than
  /// trusting the paragraph above it.
  static final Paint _backing = Paint()..color = const Color(palette.hudSurface);
  static final Paint _cardBorder = Paint()
    ..color = const Color(palette.panelBorder)
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
        color: Color(palette.ink),
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
