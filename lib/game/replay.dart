/// Deterministic replay: a whole run, stored as a seed plus the frames the
/// player tapped on, and re-executed frame for frame.
///
/// ============================================================================
/// WHAT MAKES THIS POSSIBLE, AND WHY IT IS NOT AN ACHIEVEMENT OF THIS FILE
/// ============================================================================
///
/// `GameModel` reads no clock, holds no randomness and is immutable, so
/// `tick(dt)` is a pure function from (snapshot, seconds) to snapshot. Two
/// machines handed the same starting snapshot and the same sequence of calls
/// therefore produce byte-identical doubles at every step — IEEE-754 addition
/// and multiplication are exactly specified, and nothing in the model does
/// anything else. All this file adds is a way to WRITE DOWN that sequence of
/// calls and a driver that makes it again.
///
/// ============================================================================
/// THE THREE THINGS A RECORDING HAS TO PIN, AND WHY EACH ONE
/// ============================================================================
///
/// 1. **The seed.** The taps are only half a run; the course is the other half.
///    See `course_seed.dart` — the same taps on two courses are two runs.
///
/// 2. **The timestep.** The model takes `dt` as a parameter, which is exactly
///    what stops it depending on a clock, and is also exactly what makes "the
///    same taps" ambiguous until somebody says how long a frame is. A tap on
///    frame 40 of a 60 Hz run and a tap on frame 40 of a 30 Hz run are two
///    different moments. So a replay is stated at ONE fixed timestep,
///    [replayFrameSeconds], and nothing in a recording ever refers to real
///    time. A phone that stutters, a laptop that renders at 144 Hz and a test
///    where no time passes at all replay the identical run — that is what
///    [FixedStepAccumulator] is for, and it is why the live game steps in fixed
///    chunks rather than handing Flame's frame duration to the model.
///
/// 3. **When a tap lands relative to the physics.** One frame is
///
///        if (this frame is a tap frame) model = model.flap();
///        model = model.tick(replayFrameSeconds);
///
///    — tap FIRST, then that frame's physics. Same convention as
///    `tool/headless_sim.dart`, which is where it was first written down; if
///    the two ever disagreed, every fairness witness would start describing a
///    different game. `test/replay_test.dart` pins them to each other frame by
///    frame rather than trusting the comment.
///
/// ============================================================================
/// WHY THE TAPS ARE A LIST OF FRAME NUMBERS AND NOT A BOOL PER FRAME
/// ============================================================================
///
/// A minute of play is 3600 frames and perhaps 120 taps. `List<bool>` spends a
/// slot on all 3600 to say "no" 3480 times; a list of the 120 frame numbers
/// that were taps says the same thing and is the natural shape of the data —
/// input is an event, not a per-frame quantity. It also encodes far smaller,
/// which is what makes `run_code.dart` able to fit a real run in a chat
/// message.
///
/// Same directory rule as the rest of `lib/game/`: no Flame, no Flutter, no
/// clock, no randomness.
library;

import 'course_seed.dart';
import 'game_model.dart';

/// The one timestep every replay is stated in: 60 frames per second.
///
/// Not a parameter. A replay recorded at one timestep and replayed at another
/// is a different run — the taps land at different points in the trajectory —
/// so letting a caller choose would turn "this replays exactly" into "this
/// replays exactly if you remember which number to pass". One constant, and the
/// recording never has to carry it.
const double replayFrameSeconds = 1.0 / 60.0;

/// The longest run a replay may describe: one hour of play.
///
/// WHY A RECORDING HAS AN UPPER BOUND AT ALL: a run code is untrusted input
/// from a stranger, and re-executing it is how it gets verified. A code
/// claiming two billion frames costs a verifier an afternoon of CPU to reject.
/// The cap turns that into an immediate, cheap "no". One hour is roughly two
/// orders of magnitude longer than any run this game has ever produced.
const int maxReplayFrames = 216000;

/// A complete run: which course, how long, and which frames were taps.
///
/// Immutable and value-compared, for the same reasons `GameModel` is — a replay
/// is a value, so "the same run" is a comparison and not an argument about
/// object identity.
class Replay {
  /// Which course. See `course_seed.dart`; 0 is the shipped course.
  final int seed;

  /// The frames the player tapped on: strictly increasing, every entry in
  /// `[0, frames)`.
  ///
  /// Strictly increasing rather than merely sorted, because two taps on one
  /// frame is not a thing the game can observe. A flap ASSIGNS velocity, so a
  /// second flap inside the same frame changes nothing at all — allowing
  /// duplicates would let two different recordings describe one identical run,
  /// and then `decode(encode(r)) == r` would stop being a fair test of the
  /// encoder.
  final List<int> tapFrames;

  /// How many frames of physics the run lasted.
  final int frames;

  /// Builds a replay, rejecting anything that is not a run.
  ///
  /// The checks are here, in the constructor, rather than in the decoder that
  /// will mostly be feeding it: a `Replay` that exists is a `Replay` that means
  /// something, so no code downstream has to re-ask. The decoder turns these
  /// throws into a verdict.
  Replay({
    required this.seed,
    required List<int> tapFrames,
    required this.frames,
  }) : tapFrames = List<int>.unmodifiable(tapFrames) {
    if (seed < 0 || seed > maxCourseSeed) {
      throw ArgumentError.value(seed, 'seed', 'must be 0..$maxCourseSeed');
    }
    if (frames < 0 || frames > maxReplayFrames) {
      throw ArgumentError.value(frames, 'frames', 'must be 0..$maxReplayFrames');
    }
    // Indexed rather than carried in a `previous` variable seeded to -1. That
    // sentinel is a constant no input can reach: -1 and -2 both make the first
    // comparison false, so `tool/mutate.dart` could change it freely and every
    // test stayed green. Comparing element i against element i - 1 has no
    // magic starting value to get wrong.
    for (int i = 0; i < this.tapFrames.length; i++) {
      final int tap = this.tapFrames[i];
      if (i > 0 && tap <= this.tapFrames[i - 1]) {
        throw ArgumentError.value(
          tapFrames,
          'tapFrames',
          'must be strictly increasing',
        );
      }
      if (tap < 0 || tap >= frames) {
        throw ArgumentError.value(
          tap,
          'tapFrames',
          'frame out of range 0..${frames - 1}',
        );
      }
    }
  }

  /// The course this run was played on.
  GapPattern get gapPattern => gapPatternForSeed(seed);

  /// The snapshot every replay of this run starts from.
  GameModel get startModel => GameModel.ready(gapCentreFor: gapPattern);

  /// How long the run lasted in seconds, at the fixed timestep. For reports
  /// only — nothing in the replay machinery uses it.
  double get seconds => frames * replayFrameSeconds;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Replay) return false;
    if (other.seed != seed || other.frames != frames) return false;
    if (other.tapFrames.length != tapFrames.length) return false;
    for (int i = 0; i < tapFrames.length; i++) {
      if (other.tapFrames[i] != tapFrames[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(seed, frames, Object.hashAll(tapFrames));

  @override
  String toString() =>
      'Replay(seed: $seed, frames: $frames, taps: ${tapFrames.length})';
}

/// Re-executes a [Replay] one frame at a time.
///
/// A cursor rather than a set membership test: the tap frames are already
/// sorted, so "is this frame a tap" is one comparison against the next
/// outstanding tap. It also means a replay of a million frames allocates
/// nothing per frame.
///
/// This class is the ONLY place the tap-then-tick convention is written in
/// `lib/game/`. Everything that replays anything — the verifier, the ghost in
/// `lib/main.dart`, the round-trip proof — goes through it, so there is no
/// second loop that can drift out of step with this one.
class ReplayPlayer {
  /// The run being replayed.
  final Replay replay;

  GameModel _model;
  int _frame = 0;
  int _cursor = 0;

  ReplayPlayer(this.replay) : _model = replay.startModel;

  /// The snapshot after the frames stepped so far. Before the first [step] this
  /// is the run's starting model.
  GameModel get model => _model;

  /// How many frames have been stepped.
  int get frame => _frame;

  /// True once every frame of the recording has been replayed.
  bool get done => _frame >= replay.frames;

  /// Advances exactly one frame. Returns false, and does nothing, once the
  /// recording is exhausted.
  ///
  /// Deliberately does NOT stop early when the model dies. A recording knows
  /// how many frames it lasted; re-deciding that from the model's state here
  /// would mean the player and the recorder each had an opinion about when a
  /// run ends. Ticking a dead model is a no-op — `tick` returns the receiver —
  /// so the extra frames, if a recording somehow has any, cost nothing and
  /// change nothing.
  bool step() {
    if (done) return false;
    if (_cursor < replay.tapFrames.length &&
        replay.tapFrames[_cursor] == _frame) {
      _model = _model.flap();
      _cursor++;
    }
    _model = _model.tick(replayFrameSeconds);
    _frame++;
    return true;
  }
}

/// Replays [replay] to its end and returns the final snapshot.
GameModel replayFinalModel(Replay replay) {
  final ReplayPlayer player = ReplayPlayer(replay);
  while (player.step()) {}
  return player.model;
}

/// Replays [replay] and returns the snapshot after every frame, starting with
/// the frame-0 model before anything has been stepped.
///
/// So the list has `frames + 1` entries and `trace[k]` is the state after `k`
/// frames. This is what "replays frame-exactly" is checked against: comparing
/// only the last entry would pass for two runs that diverged and happened to
/// re-converge, which is a thing floating-point trajectories can do.
List<GameModel> replayTrace(Replay replay) {
  final ReplayPlayer player = ReplayPlayer(replay);
  final List<GameModel> trace = <GameModel>[player.model];
  while (player.step()) {
    trace.add(player.model);
  }
  return trace;
}

/// Drives a live run at the fixed timestep and writes down what happened.
///
/// The recorder is the WRITE side of exactly the same loop [ReplayPlayer] is
/// the READ side of. Both call `flap()` before `tick()` and both step by
/// [replayFrameSeconds], which is why a recording plays back as itself; a test
/// checks that by recording a run and replaying it frame for frame rather than
/// by reading these two classes and agreeing they look similar.
class ReplayRecorder {
  /// The course being played.
  final int seed;

  /// The most frames this recording may reach before it stops on its own.
  ///
  /// Defaults to [maxReplayFrames], which is the only value the game itself
  /// ever uses. It is a PARAMETER rather than a hard-wired constant for one
  /// reason, and it is worth being honest about which: the ceiling is otherwise
  /// unreachable in a test. Proving that the recorder stops on the cap's frame
  /// and not one after it means running a recorder to the cap, and at 216,000
  /// frames that is a test nobody would write — so the boundary would go
  /// unchecked, which is exactly the hole `tool/mutate.dart` found here.
  /// `test/replay_test.dart` runs a three-frame cap instead.
  final int frameCap;

  final List<int> _taps = <int>[];
  GameModel _model;
  int _frame = 0;
  bool _tapPending = false;

  ReplayRecorder({this.seed = 0, this.frameCap = maxReplayFrames})
    : _model = GameModel.ready(gapCentreFor: gapPatternForSeed(seed));

  /// The current snapshot.
  GameModel get model => _model;

  /// Frames stepped so far.
  int get frame => _frame;

  /// True once the run is over — either the car died or the recording reached
  /// [frameCap].
  bool get finished => _model.state == RunState.dead || _frame >= frameCap;

  /// Records a tap. It lands on the next frame [step] runs, never on the one
  /// already behind us.
  ///
  /// WHY TAPS ARE QUEUED RATHER THAN APPLIED IMMEDIATELY: a real tap arrives
  /// from a touch handler at some arbitrary point between two frames, and the
  /// number of times that happens inside one frame is a fact about the
  /// operating system, not about the game. Queuing quantises input to the frame
  /// grid, which is the only grid a recording can express — and it costs
  /// nothing, because a flap ASSIGNS velocity, so two taps inside one frame
  /// were always going to produce exactly one flap's worth of motion.
  void tap() {
    _tapPending = true;
  }

  /// Advances one fixed frame. Returns false, and does nothing, once
  /// [finished].
  bool step() {
    if (finished) return false;
    if (_tapPending) {
      _tapPending = false;
      // Recorded even when the model ignores it — a tap while `dead` is a tap
      // the player made. It cannot happen here, because `finished` guards the
      // dead state, but the rule matters: the recording describes the INPUT,
      // and re-deciding which inputs "counted" would put a second copy of the
      // game's rules in the recorder.
      _taps.add(_frame);
      _model = _model.flap();
    }
    _model = _model.tick(replayFrameSeconds);
    _frame++;
    return true;
  }

  /// The run so far, as a value that can be encoded, stored and replayed.
  Replay get replay =>
      Replay(seed: seed, tapFrames: _taps, frames: _frame);
}

/// Turns a stream of real, jittery frame durations into whole fixed steps.
///
/// WHY THE LIVE GAME NEEDS THIS AT ALL:
///
/// Flame hands `update` however long the last frame actually took — 16.1 ms,
/// then 31.9 ms because the OS scheduled something else, then 8.3 ms on a
/// 120 Hz panel. Feeding those straight to `tick` is perfectly legal and the
/// game plays fine, but the run becomes a function of the device's frame pacing
/// and cannot be written down: replaying "the taps" would land them at
/// different points in the trajectory. Accumulating real time and spending it
/// in whole [replayFrameSeconds] chunks makes the SIMULATION frame-rate
/// independent while the DISPLAY stays as smooth as the device manages.
///
/// THE CAP, AND WHY DROPPING TIME IS THE RIGHT FAILURE: after a long stall —
/// the app was backgrounded, a garbage collection ran, a debugger was attached
/// — the accumulator holds seconds of debt. Spending all of it at once means
/// hundreds of physics steps inside one frame, which takes longer than a frame,
/// which produces more debt: the spiral of death, and the player watches the
/// car teleport into a pipe. [maxStepsPerCall] refuses that, and the surplus is
/// discarded rather than banked. The game loses a slice of wall-clock time; it
/// never loses determinism, because a recording counts FRAMES and is completely
/// indifferent to how much real time each one was supposed to represent.
class FixedStepAccumulator {
  /// The most physics steps one call to [stepsFor] will ever authorise.
  ///
  /// Five is about 83 ms of catch-up per frame: enough to ride out an ordinary
  /// hitch without visibly slowing down, small enough that a real stall is
  /// dropped instead of being replayed at the player.
  final int maxStepsPerCall;

  double _carry = 0.0;

  FixedStepAccumulator({this.maxStepsPerCall = 5});

  /// Unspent real time, in seconds. Always in `[0, replayFrameSeconds)` after a
  /// call to [stepsFor]. Exposed for tests.
  double get carry => _carry;

  /// How many whole frames [realSeconds] of wall-clock time buys.
  ///
  /// A negative or non-finite duration buys nothing and is not banked. Flame
  /// should never produce one, but "should never" is not a guard, and a NaN
  /// entering the accumulator would poison every later frame permanently.
  int stepsFor(double realSeconds) {
    if (!(realSeconds > 0)) return 0;
    _carry += realSeconds;
    int steps = 0;
    while (_carry >= replayFrameSeconds && steps < maxStepsPerCall) {
      _carry -= replayFrameSeconds;
      steps++;
    }
    if (_carry >= replayFrameSeconds) {
      // The loop stops for one of two reasons: the carry ran out, or the cap
      // did. Carry still holding a whole frame means it was the cap — so this
      // one comparison says "we went over budget" without a second one asking
      // whether `steps` reached the limit, which could only ever agree with it.
      //
      // The surplus is thrown away rather than owed. See the class comment:
      // banking it is the spiral.
      _carry = 0.0;
    }
    return steps;
  }
}
