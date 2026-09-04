/// A headless driver for [GameModel] — the game with no window, no canvas and
/// no frame pump.
///
/// WHY THIS EXISTS SEPARATELY FROM THE GAME:
///
/// `lib/game/` is already pure Dart with time as a parameter, so a run is just
/// a loop of `flap()` and `tick(dt)` calls. This file is that loop, written once
/// so that every caller — a test, a `dart run` script, the fairness prover
/// checking a witness — drives the model the same way. Two callers that each
/// write their own loop will eventually disagree about whether the flap comes
/// before or after the tick, and then they are measuring two different games.
///
/// THE INPUT MODEL, STATED ONCE: one frame is
///
///     if (policy says flap) model = model.flap();
///     model = model.tick(dt);
///
/// A flap is decided at most once per frame, and it lands *before* that frame's
/// physics. That matches a real player, whose tap is sampled by the frame loop,
/// and it is the same convention the fairness prover searches over. If these two
/// ever drift apart, the prover stops proving anything about this game.
///
/// No Flutter, no Flame, no `dart:io` — so it runs under `dart run` and under
/// `flutter test` unchanged.
library;

import 'package:flappymiata/game/game_model.dart';

/// One frame at 60fps. The model never asks what the frame rate is, so the
/// driver supplies it; nothing here reads a clock.
const double frameSeconds = 1.0 / 60.0;

/// A player. Given the model at the top of a frame and the frame number,
/// answers "tap now?".
///
/// Deliberately a plain function and not a class: a policy has no state of its
/// own that the model does not already carry, and keeping it a function means a
/// recorded input sequence (`List<bool>`) is a policy too — see [replayPolicy].
typedef Policy = bool Function(GameModel model, int frame);

/// How a run ended.
enum SimOutcome {
  /// Still alive when the driver stopped — either it hit its frame budget or it
  /// reached the score it was asked for. Not a loss.
  survived,

  /// Died overlapping a pipe.
  hitPipe,

  /// Died by leaving the top or the bottom of the playfield.
  leftPlayfield,
}

/// What one headless run produced.
class SimResult {
  /// How the run ended.
  final SimOutcome outcome;

  /// The model's own score at the end.
  final int score;

  /// Frames of physics actually applied — i.e. calls to `tick`.
  final int frames;

  /// Obstacles the car got past, counted by this driver rather than read off
  /// the model.
  ///
  /// WHY COUNT IT TWICE: [score] is the model's answer and this is the driver's,
  /// arrived at by watching obstacles cross behind the car. They must agree. A
  /// scoring bug that paid out twice, or never, would show up as a mismatch
  /// instead of as a plausible-looking number, and `test/headless_sim_test.dart`
  /// asserts they match on every run it does.
  final int obstaclesPassed;

  /// How many frames the policy asked to flap on.
  final int flaps;

  /// The final model, for callers that want to look at where the car ended up.
  final GameModel finalModel;

  /// The inputs that produced this run, one bool per frame, when the caller
  /// asked for them. This is what turns "some policy survived" into a replayable
  /// artefact.
  final List<bool>? inputs;

  const SimResult({
    required this.outcome,
    required this.score,
    required this.frames,
    required this.obstaclesPassed,
    required this.flaps,
    required this.finalModel,
    this.inputs,
  });

  /// True when the car was still alive when the driver stopped.
  bool get alive => outcome == SimOutcome.survived;

  @override
  String toString() =>
      'outcome=${outcome.name} score=$score obstaclesPassed=$obstaclesPassed '
      'frames=$frames flaps=$flaps finalY=${finalModel.y.toStringAsFixed(4)}';
}

/// Runs [start] forward under [policy] at a fixed [dt] and reports what
/// happened.
///
/// Stops on death, on reaching [maxFrames], or as soon as the score reaches
/// [untilScore] if one is given.
///
/// [recordInputs] keeps the frame-by-frame tap record so the run can be replayed
/// later through [replay]; it costs one bool per frame, so it is off by default
/// for the long runs the fairness tool does.
SimResult runHeadless({
  GameModel? start,
  required Policy policy,
  double dt = frameSeconds,
  int maxFrames = 20000,
  int? untilScore,
  bool recordInputs = false,
}) {
  // A `ready` model does not move: `tick` returns the receiver untouched, so a
  // run that never flaps never begins. Starting from `ready` and letting the
  // policy take the first frame is therefore safe — the driver does not have to
  // secretly flap on the caller's behalf.
  GameModel model = start ?? const GameModel.ready();

  final List<bool>? inputs = recordInputs ? <bool>[] : null;
  int frames = 0;
  int flaps = 0;

  // Obstacle indices this driver has watched cross behind the car. A set rather
  // than a counter because an obstacle is behind the car for roughly 33 frames
  // and must only be counted once — the same edge-versus-level problem the model
  // solves with its `scored` flag, solved here independently so the two answers
  // are genuinely separate evidence.
  final Set<int> passed = <int>{};
  final double carLeft = GameModel.carX - GameModel.carWidth / 2;

  while (frames < maxFrames) {
    if (untilScore != null && model.score >= untilScore) break;

    final bool tap = policy(model, frames);
    if (inputs != null) inputs.add(tap);
    if (tap) {
      flaps++;
      model = model.flap();
    }

    model = model.tick(dt);
    frames++;

    for (final Obstacle obstacle in model.obstacles) {
      if (obstacle.right < carLeft) passed.add(obstacle.index);
    }

    if (model.state == RunState.dead) break;
  }

  return SimResult(
    outcome: _classify(model),
    score: model.score,
    frames: frames,
    obstaclesPassed: passed.length,
    flaps: flaps,
    finalModel: model,
    inputs: inputs,
  );
}

/// Which of the two deaths killed this model.
///
/// The model itself distinguishes them by where it leaves the car: a
/// bounds death pins y to the edge that was crossed, a pipe death leaves y
/// wherever the crash happened. That is documented in `tick`, and it is the only
/// signal available from outside, so it is the one used here.
SimOutcome _classify(GameModel model) {
  if (model.state != RunState.dead) return SimOutcome.survived;
  if (model.y == GameModel.minY || model.y == GameModel.maxY) {
    return SimOutcome.leftPlayfield;
  }
  return SimOutcome.hitPipe;
}

/// A policy that plays back a recorded tap sequence, then stops tapping.
///
/// This is how a fairness witness gets checked: the prover hands over a list of
/// booleans, and this replays them through the real [GameModel]. If the car is
/// still alive at the end, the proof is not a claim about a search any more —
/// it is a button sequence anybody can re-run.
Policy replayPolicy(List<bool> inputs) =>
    (GameModel model, int frame) => frame < inputs.length && inputs[frame];

/// Replays [inputs] through the real model and reports what happened.
SimResult replay(
  List<bool> inputs, {
  GameModel? start,
  double dt = frameSeconds,
}) => runHeadless(
  start: start,
  policy: replayPolicy(inputs),
  dt: dt,
  maxFrames: inputs.length,
);

// -----------------------------------------------------------------------------
// A few stock policies. None of these is used to decide fairness — see
// `tool/fairness.dart` for why no sampled policy can — but they are useful for
// smoke-testing the driver and for showing what an ordinary run looks like.
// -----------------------------------------------------------------------------

/// Never taps at all.
///
/// The run therefore never leaves `ready`, and nothing happens for as long as
/// the driver is willing to wait — `tick` returns the receiver untouched while
/// the state is `ready`. That is not a bug in the driver, it is the property the
/// fairness prover leans on: waiting before the first tap costs nothing, so the
/// search can start its clock at the first tap without losing any options.
bool neverFlap(GameModel model, int frame) => false;

/// Taps once to start the run, then never again. The car falls out of the
/// bottom of the playfield.
bool startThenDrop(GameModel model, int frame) => model.state == RunState.ready;

/// Taps every frame. Velocity is *assigned* by a flap, so this does not build up
/// speed: it pins the car to a steady climb of `flapImpulse + gravity * dt` and
/// it leaves through the ceiling.
bool alwaysFlap(GameModel model, int frame) => true;

/// Taps whenever the car is below [target]. A crude altitude hold — it wobbles
/// around the target by roughly one flap arc.
///
/// The `ready` clause is the tap that starts the run; without it a policy whose
/// target sits below [GameModel.startY] would never tap at all and the run would
/// sit frozen forever.
Policy holdAltitude(double target) => (GameModel model, int frame) =>
    model.state == RunState.ready || model.y > target;

/// Aims at the centre of the next gap the car has not yet passed, falling back
/// to mid-field when there is nothing ahead.
///
/// This is a *heuristic*, and heuristics are exactly what the fairness prover
/// refuses to draw conclusions from. It is here to make `tool/simulate.dart`
/// print something recognisable as play, and for nothing else.
Policy chaseGap({double lead = 0.02}) {
  return (GameModel model, int frame) {
    if (model.state == RunState.ready) return true;
    final double carRight = GameModel.carX + GameModel.carWidth / 2;
    double target = 0.5;
    for (final Obstacle obstacle in model.obstacles) {
      if (obstacle.right > carRight - GameModel.carWidth) {
        target = obstacle.gapCentre;
        break;
      }
    }
    // Aim slightly above the gap centre: the car is always accelerating
    // downward, so tapping only once it is already level with the target is
    // permanently late.
    return model.y > target - lead;
  };
}
