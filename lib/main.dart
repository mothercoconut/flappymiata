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
class FlappyMiataGame extends FlameGame with TapCallbacks {
  /// Which course this session plays. Fixed for the life of the game object, so
  /// a restart puts the player on the same obstacles — otherwise "beat your
  /// ghost" would be a different question every attempt.
  final int courseSeed;

  FlappyMiataGame({int? courseSeed})
    : courseSeed = courseSeed ?? todaysCourseSeed();

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

  /// The best run of this session, kept so the next one can race it.
  ///
  /// IN MEMORY ONLY, and deliberately: writing it to disk would mean a storage
  /// dependency, and this repo does not add one without being asked. The
  /// replay is a seed plus a list of small integers — a run code, which
  /// `lib/game/run_code.dart` will already turn into a short string — so
  /// persisting it later is a one-line change to this field and nothing else.
  Replay? _bestRun;

  /// The score [_bestRun] achieved.
  int _bestScore = 0;

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

    // So the "tap to start" hint is on screen for the very first frame, rather
    // than appearing only once `update` has run once.
    _panel.text = _hudText;
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

  /// A tap means "flap" during a run and "start again" once the run is over.
  ///
  /// The tap is QUEUED rather than applied here. A touch handler fires whenever
  /// the operating system feels like it, possibly twice between two frames, and
  /// a recording can only express input on the frame grid. `ReplayRecorder.tap`
  /// therefore lands the tap on the next fixed step — which is also what the
  /// model would have done anyway, since a flap assigns velocity and two flaps
  /// inside one frame produce exactly one flap's worth of motion.
  @override
  void onTapDown(TapDownEvent event) {
    if (_run.finished) {
      _startRun();
    } else {
      _run.tap();
    }
    _panel.text = _hudText;
  }

  /// Begins a fresh run on the same course, and puts the best run so far on the
  /// track alongside it.
  void _startRun() {
    _run = ReplayRecorder(seed: courseSeed);

    final Replay? best = _bestRun;
    if (best == null) {
      _ghost = null;
      return;
    }
    final ReplayPlayer ghost = ReplayPlayer(best);

    // SKIP THE GHOST'S OWN THINKING TIME. A recording includes every frame from
    // the moment the run object was created, including however long its player
    // sat looking at the "tap to start" screen. Those frames do nothing — the
    // model is `ready` and `tick` returns the receiver — but replaying them
    // would leave the ghost idling on the start line while the live car drove
    // off. Fast-forwarding to the frame of its first tap lines the two runs up
    // at the moment each of them actually began, which is the only alignment
    // that makes a race mean anything.
    //
    // A recording with NO taps never began at all, so the whole thing is
    // lead-in: the ghost is wound to its end and parks on the start line, which
    // is exactly where that run spent every frame of its life.
    final int leadIn =
        best.tapFrames.isEmpty ? best.frames : best.tapFrames.first;
    for (int i = 0; i < leadIn; i++) {
      ghost.step();
    }
    _ghost = ghost;
  }

  @override
  void update(double dt) {
    super.update(dt);

    // THE ONE PLACE REAL TIME ENTERS. Flame measures how long the frame took;
    // the accumulator turns that into a whole number of fixed steps, and the
    // model never learns that a clock was involved. That indirection is why an
    // identical run can be replayed exactly in a test where no real time passes
    // at all — and why the ghost stays in step with the live car on a device
    // that stutters.
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

    // THE FIRST FINISHED RUN IS ALWAYS KEPT, however badly it went. A ghost
    // that only appeared once somebody scored would leave the player with
    // nothing to race on exactly the attempts where a reference would help
    // most, and "my previous attempt" is the comparison a player is actually
    // making in their head.
    //
    // Idempotent: after the first capture `_bestRun` is non-null and
    // `score > _bestScore` is false, so this does nothing on every later frame.
    // No "have I already saved this" flag to get out of step with the thing it
    // is describing.
    if (_run.finished && (_bestRun == null || _run.model.score > _bestScore)) {
      _bestScore = _run.model.score;
      _bestRun = _run.replay;
    }

    _panel.text = _hudText;
  }

  /// The score, the best of the session, and a hint in the two states where the
  /// game is waiting on the player. No hint while playing: it would be one more
  /// thing sitting over the pipes with nothing left to say.
  String get _hudText {
    final String score = 'score: ${_run.model.score}';
    final String best = _bestRun == null ? '' : '\nbest: $_bestScore';
    switch (_run.model.state) {
      case RunState.ready:
        return '$score$best\ntap to start';
      case RunState.playing:
        return '$score$best';
      case RunState.dead:
        return '$score$best\ntap to restart';
    }
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

/// The score and hint text on an opaque backing panel, at [_hudPriority] —
/// above everything the world layer draws.
///
/// WHY THE BACKING IS NOT DECORATION: priority fixes the ordering, and ordering
/// alone does not fix legibility. Pale glyphs sitting directly on the bright
/// green of a pipe are a contrast problem rather than a depth one, and they
/// stay hard to read even once they are unmistakably in front. An opaque
/// rectangle underneath makes the colour behind the text a known quantity no
/// matter what is passing beneath it.
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
  static final Paint _cardBacking = Paint()..color = const Color(0xF20A1D32);
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

  final TextComponent _stateReadout = TextComponent(
    anchor: Anchor.center,
    textRenderer: TextPaint(
      style: const TextStyle(
        color: Color(0xFFFFFFFF),
        fontSize: 26.0,
        fontWeight: FontWeight.w800,
        height: 1.25,
        letterSpacing: 1.5,
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
    switch (game.model.state) {
      case RunState.ready:
        _stateReadout.text = 'READY\nTAP TO DRIVE';
      case RunState.playing:
        _stateReadout.text = '';
      case RunState.dead:
        _stateReadout.text = 'RUN OVER\nTAP TO RESTART';
    }
  }

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    await addAll(<Component>[_readout, _stateReadout]);
  }

  @override
  void render(Canvas canvas) {
    final RRect scoreRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.x, size.y),
      const Radius.circular(10),
    );
    canvas.drawRRect(scoreRect.shift(const Offset(0, 4)), _cardBorder);
    canvas.drawRRect(scoreRect, _backing);

    if (game.model.state == RunState.playing) return;

    _stateReadout.position = Vector2(game.size.x / 2, game.size.y * 0.42);
    final double cardWidth = game.size.x * 0.72;
    final double cardHeight = 116;
    final Rect cardRect = Rect.fromLTWH(
      (game.size.x - cardWidth) / 2,
      game.size.y * 0.33,
      cardWidth,
      cardHeight,
    );
    final RRect card = RRect.fromRectAndRadius(
      cardRect,
      const Radius.circular(16),
    );
    canvas.drawRRect(card.shift(const Offset(0, 6)), _cardBorder);
    canvas.drawRRect(card, _cardBacking);
  }
}
