/// Assist mode: where the flap window for the next obstacle actually is.
///
/// ============================================================================
/// WHY THIS IS IN `lib/ui/` AND CAN NEVER BE IN `lib/game/`
/// ============================================================================
///
/// It draws nothing itself — it is plain Dart with no Flame and no Flutter — but
/// it is presentation all the same, and the directory it lives in is the
/// statement that it is. `lib/game/` owns the RULES. Assist changes no rule: it
/// reads a `GameModel`, returns some numbers, and hands them back. Nothing here
/// is ever called by `tick`, nothing here is on the path from a tap to a
/// position, and nothing here can be.
///
/// That is not a stylistic preference, it is what keeps every other guarantee in
/// the repository true. A run is a seed plus a list of tap frames
/// (`lib/game/replay.dart`); a stored best score is believed only because the
/// run is RE-EXECUTED and produces the same number
/// (`lib/game/verified_score.dart`); the fairness prover certifies courses by
/// reproducing `GameModel.tick` frame for frame. All three rest on the model
/// being a pure function of (seed, taps). The moment a display setting could
/// reach the model, "the same taps" would stop describing the same run: two
/// players tapping identically would score differently depending on a toggle,
/// every recorded run would have to carry the toggle, and every record made
/// before the toggle existed would stop verifying.
///
/// So the arrow points one way. `test/assist_test.dart` asserts it the only way
/// that means anything: it plays the same inputs twice, once consulting this
/// file on every frame and once never touching it, and requires the two traces
/// to be equal frame for frame — models, scores and risk scores included.
///
/// ============================================================================
/// WHAT THE CHEAP SOLVER IS, AND WHAT IT APPROXIMATES
/// ============================================================================
///
/// `tool/fairness.dart` answers "can a perfect player clear this course?" by
/// enumerating the set of every state a player could be in, for the whole
/// course, and asking whether it is ever empty. It is a FORWARD search, it runs
/// to the end of the course, and it costs far too much to do sixty times a
/// second.
///
/// The three things that make it expensive are not the same three things:
///
///   1. it covers the whole course;
///   2. it answers one question — "is SOME path alive" — so getting the answer
///      for each of the 45 moments the player might tap would mean 45 searches;
///   3. it is redone from scratch each time it is asked.
///
/// This file keeps the physics EXACTLY and attacks all three:
///
///   1. **The horizon is bounded.** The search stops once the next obstacle has
///      gone past the car, plus [assistLookaheadFrames] so the advice is not
///      blind to the pipe immediately behind it. Around 130 frames instead of
///      the whole run.
///   2. **The search runs BACKWARDS.** Going forwards, "could I survive if I
///      tapped now?" is one question per candidate tap. Going backwards it is
///      one search for all of them: the pass computes, for every frame, the SET
///      of states from which some continuation survives to the end of the
///      horizon, and then every candidate tap is a single bit lookup into that
///      set. One pass, 45 answers.
///   3. **A pass is reused for about a second.** The set of surviving states is
///      a property of the WORLD, not of the player — obstacles move, spawn and
///      are dropped without ever reading the car's position, which is the
///      observation `tool/fairness.dart` is built on too. So nothing the player
///      does invalidates a pass, taps included. A pass is redone only when the
///      cursor runs off the end of it, roughly once per [assistPreviewFrames].
///
/// Everything else is the prover's own machinery: the same (y, framesSinceFlap)
/// state, the same exact lattice, the same bitmaps, the same pessimistic
/// epsilon. Within its horizon the answer is not an estimate.
///
/// ============================================================================
/// WHERE IT IS WRONG — THE PART THAT MATTERS
/// ============================================================================
///
/// The window is drawn from a proof, so it never highlights a tap the physics
/// cannot support. Every way it can still mislead is therefore a way it says
/// too little, or says something true about too short a future:
///
///   * **It is honest about the horizon and silent past it.** "Flapping now
///     leaves a surviving continuation" is a claim about the next obstacle and
///     the [assistLookaheadFrames] after it, and about nothing further. A tap
///     inside the window can still put the car somewhere that dooms it two
///     obstacles later. This is the one direction in which the advice is
///     OPTIMISTIC, and it is unavoidable — a window that accounted for the
///     whole run would be the full prover.
///   * **It says a continuation EXISTS, not that any continuation works.**
///     Every highlighted frame is backed by a surviving sequence of taps, but
///     the player still has to fly it. The window is where a good line is
///     available, not where safety is automatic.
///   * **It errs pessimistic at the pipe lips.** Survival is tested with
///     [assistEpsilon] of extra clearance demanded, exactly as the prover does,
///     so a line that clears a pipe by less than a nanometre is not offered.
///   * **It errs pessimistic at the top of the counter.** States that have been
///     falling for [assistMaxRows] frames are dropped rather than represented.
///     A car cannot be inside the playfield after 80 such frames, so the bound
///     is unreachable in practice; where it is not, dropping states can only
///     shrink the window.
///   * **The trajectory is a closed form, the game is a running sum.** The two
///     differ by floating-point noise around 1e-13 over a horizon this long —
///     four orders of magnitude inside the epsilon above. Same argument as the
///     header of `tool/fairness.dart`.
///
/// ============================================================================
/// UNVERIFIED ON HARDWARE
/// ============================================================================
///
/// No emulator or device was available. The solver's ANSWERS are checked hard —
/// `test/assist_test.dart` replays every tap the window offers through the real
/// `GameModel` and requires the car to come out alive — but its COST is measured
/// on a desktop VM, and how the highlight LOOKS on a phone, whether the path is
/// legible over the pipes, and whether it is a help or a distraction while
/// actually playing, are all unverified.
library;

import 'dart:typed_data';

import 'package:flappymiata/game/game_model.dart';
import 'package:flappymiata/game/replay.dart';

// -----------------------------------------------------------------------------
// Tuning. Every one of these trades cost against how much of the future the
// advice can see, and each says which way it fails when it runs out.
// -----------------------------------------------------------------------------

/// Extra clearance a state must have from every pipe to count as alive.
///
/// The same value and the same reasoning as `defaultEpsilon` in
/// `tool/fairness.dart`: the search evaluates positions in closed form while the
/// game accumulates them frame by frame, the two differ by around 1e-13, and
/// demanding 1e-9 more room than the geometry strictly requires puts the whole
/// error on the safe side. The assist can therefore fail to offer a tap that
/// would have worked; it cannot offer one that would not.
const double assistEpsilon = 1e-9;

/// Frames of extra search past the moment the next obstacle is cleared.
///
/// A window computed to exactly the moment a pipe goes behind the car is a
/// window that does not care where it leaves you, and the pipe after it is only
/// about 80 frames away. 45 is a little over half of that gap: enough that the
/// advice cannot recommend a tap which strands the car immediately, cheap enough
/// that it does not double the cost of a pass.
const int assistLookaheadFrames = 45;

/// The most frames one pass will ever search.
///
/// A hard ceiling on the work a single frame can be asked to do. It binds only
/// when the next obstacle has just spawned AND the lookahead is added on top;
/// when it binds, the horizon is simply shorter and the advice is
/// correspondingly shorter-sighted, which is the honest failure.
const int assistMaxFrames = 200;

/// How many frames of a pass are kept for the player to be advised from.
///
/// The backward search produces frames in DESCENDING order, so the ones nearest
/// to now are the last ones computed — which is why only this many have to be
/// stored, and why the memory a pass needs does not grow with the horizon.
/// A second of advice, and a second between passes.
const int assistPreviewFrames = 60;

/// Rows in the state bitmap: the largest `framesSinceFlap` represented.
///
/// PHYSICS, NOT A TUNING KNOB. A car that flapped from the very top of the
/// playfield and never flapped again is below the floor after 80 frames —
/// `80 * flapImpulse * dt + gravity * dt^2 * (80 * 81 / 2)` is 1.02 — so no live
/// state has a counter near this. Unlike the prover, which throws when it
/// reaches its cap because dropping states there would make a proof unsound,
/// dropping them HERE only removes lines from the offer, so the bound is a quiet
/// clamp rather than an error.
const int assistMaxRows = 88;

/// Bits in one machine word of the reachable-set bitmaps.
const int _wordBits = 64;

/// Words per row.
///
/// A row spans the playfield in lattice cells: `1 / (gravity * dt^2)` is 1637 of
/// them, plus slack for where each frame's lattice origin rounds. 27 * 64 = 1728
/// bits. Same number, same derivation, as `tool/fairness.dart`.
const int _words = 27;

/// Bits in one row.
const int _rowBits = _words * _wordBits;

// -----------------------------------------------------------------------------
// What the solver hands back
// -----------------------------------------------------------------------------

/// What to draw this frame.
///
/// All three fields are indexed by DELAY — 0 is this frame, 1 is the next one —
/// so nothing here needs to know what a pixel is or how fast the world scrolls.
class AssistAdvice {
  /// Where the car will be after each further frame if the player does nothing,
  /// in normalised y. `path[0]` is where it is now.
  ///
  /// Exact, up to the closed-form drift described in the library header: this is
  /// the trajectory, not a sketch of one.
  final List<double> path;

  /// Whether tapping after that many further frames leaves a surviving
  /// continuation. Same length as [path].
  ///
  /// TRUE MEANS PROVED, not "looks fine". See the library header for the two
  /// senses in which it can still mislead.
  final List<bool> flapViable;

  /// The largest delay at which doing nothing is still survivable, or -1 when
  /// even doing nothing right now has no future.
  ///
  /// This is the "tap by here" mark. Past it, every continuation the search can
  /// represent is dead inside the horizon.
  final int latestSafeCoast;

  const AssistAdvice({
    required this.path,
    required this.flapViable,
    required this.latestSafeCoast,
  });

  /// True when the search found no surviving continuation at all — the car is
  /// already committed to a crash within the horizon.
  ///
  /// Worth showing rather than hiding: an assist that quietly stops drawing
  /// looks identical to an assist that has crashed, and the two want opposite
  /// reactions from whoever is watching.
  bool get doomed => latestSafeCoast < 0;

  /// First delay in the flap window, or -1 when there is none.
  int get windowStart {
    for (int d = 0; d < flapViable.length; d++) {
      if (flapViable[d]) return d;
    }
    return -1;
  }

  /// Last delay in the flap window, or -1 when there is none.
  int get windowEnd {
    for (int d = flapViable.length - 1; d >= 0; d--) {
      if (flapViable[d]) return d;
    }
    return -1;
  }

  /// Whether tapping RIGHT NOW is one of the offered taps.
  bool get flapNow => flapViable.isNotEmpty && flapViable[0];
}

/// One backward pass: the set of surviving states at each of a run of frames.
///
/// Holds no reference to the car. That is the whole reason a pass can be reused
/// across frames and across taps — see point 3 of the library header.
class AssistPlan {
  /// The run frame this pass was anchored at.
  final int baseFrame;

  /// The car's y at [baseFrame]. The lattice is measured from here.
  final double baseY;

  /// Frames of surviving-state sets held, starting at [baseFrame].
  final int storedFrames;

  /// One lattice cell, `gravity * dt^2`.
  final double cell;

  /// How far the lattice origin slides per frame, `flapImpulse * dt`.
  final double drift;

  /// `[frame][row][word]`, flattened. Bit `i` of row `n` at frame `k` means
  /// "the state `originAt(k) + i` cells up the lattice, having fallen for `n`
  /// frames, survives to the end of the horizon".
  ///
  /// BORROWED FROM THE SOLVER, NOT OWNED. A pass is about a megabyte and a half
  /// and one is built every second or so; copying it out would make assist mode
  /// a garbage generator for no benefit, since a caller only ever wants the
  /// newest pass. [_generation] is what makes the sharing safe — see
  /// [adviseAt].
  final Uint64List _safe;

  /// Lattice origin per stored frame.
  final Int32List _origins;

  /// `framesSinceFlap` at [baseFrame].
  ///
  /// Kept because it BOUNDS the rows that mean anything. A counter goes up by
  /// one per frame and is reset by a tap, so from a car that has been falling
  /// for `baseCounter` frames, nothing at frame `k` can have a counter above
  /// `baseCounter + k` — whatever the player does in between. Rows past that
  /// were never written this pass and must not be read, which is why [_isSet]
  /// checks it rather than trusting the caller.
  final int baseCounter;

  final AssistSolver _owner;

  /// Which pass this is. The solver counts them; when the count moves on, the
  /// buffer above no longer holds this pass and every answer from it would be
  /// about a different moment in the run. Checked rather than trusted, because
  /// the wrong answer here is a highlight drawn over the wrong pipe and nothing
  /// about it would look broken.
  final int _generation;

  // The four private fields are positional because Dart forbids a named
  // parameter whose name starts with an underscore, and an initialising formal
  // is the only spelling the analyzer accepts for a field assigned straight
  // from a parameter.
  const AssistPlan._(
    this._safe,
    this._origins,
    this._owner,
    this._generation, {
    required this.baseFrame,
    required this.baseY,
    required this.storedFrames,
    required this.cell,
    required this.drift,
    required this.baseCounter,
  });

  /// The largest counter row written for stored frame [k].
  int _topRow(int k) {
    final int reachable = baseCounter + k;
    return reachable < assistMaxRows - 1 ? reachable : assistMaxRows - 1;
  }

  /// False once the solver has been asked for a newer pass, which overwrites the
  /// buffer this one reads.
  bool get isCurrent => _owner.passes == _generation;

  /// The last run frame this pass can advise on.
  ///
  /// One short of the stored range, because advising on frame `k` needs to look
  /// at the surviving states at `k + 1` — that is what "would tapping now still
  /// leave a future" means.
  int get lastAdvisableFrame => baseFrame + storedFrames - 2;

  /// Whether this pass still covers [frame].
  bool covers(int frame) =>
      frame >= baseFrame && frame <= lastAdvisableFrame;

  /// The y of lattice point [s] at stored frame [k].
  double _yAt(int k, int s) => baseY + k * drift + cell * s;

  bool _isSet(int k, int row, int s) {
    if (row < 0 || row > _topRow(k)) return false;
    final int i = s - _origins[k];
    if (i < 0 || i >= _rowBits) return false;
    final int off = (k * assistMaxRows + row) * _words + (i >> 6);
    return (_safe[off] >>> (i & (_wordBits - 1))) & 1 == 1;
  }

  /// The advice for [model] as of run frame [frame].
  ///
  /// Cheap: a walk down one trajectory with a bit test per step. The expensive
  /// part already happened when the pass was built.
  ///
  /// Null when this pass does not cover [frame], or when [model] is not on the
  /// lattice this pass was built around — which happens if it is a different run
  /// altogether. Both are "ask for a new pass", not errors.
  AssistAdvice? adviseAt(GameModel model, int frame) {
    if (!isCurrent) return null;
    if (!covers(frame)) return null;
    final int k0 = frame - baseFrame;

    final int n0 = _owner.counterFor(model.velocity);
    if (n0 < 0) return null;

    // Recover which lattice point the car is standing on. Every transition adds
    // an integer number of cells to the same origin, so this is exact up to the
    // closed-form drift, and rounding is what turns that drift back into the
    // integer it started as.
    final double raw = (model.y - baseY - k0 * drift) / cell;
    final int s0 = raw.round();
    if ((raw - s0).abs() > 0.25) return null;

    final List<double> path = <double>[];
    final List<bool> viable = <bool>[];
    int latest = -1;

    int s = s0;
    int n = n0;
    for (int k = k0; k <= lastAdvisableFrame - baseFrame; k++) {
      if (!_isSet(k, n, s)) break;
      latest = k - k0;
      path.add(_yAt(k, s));
      // Tapping on this frame sends the car to (s + 1, counter 1) on the next
      // one — a flap ASSIGNS velocity, which is the property the whole state
      // representation rests on.
      viable.add(_isSet(k + 1, 1, s + 1));
      // Coasting sends it to (s + n + 1, n + 1).
      n++;
      s += n;
    }

    return AssistAdvice(
      path: path,
      flapViable: viable,
      latestSafeCoast: latest,
    );
  }
}

/// Builds passes. Owns its buffers so a pass costs no allocation after the
/// first one.
///
/// One instance per game. Not const, not static: the buffers are about a
/// megabyte and a half and there is no reason for a device that never turns
/// assist on to carry them.
class AssistSolver {
  /// Seconds per frame. The run's own timestep, imported rather than repeated,
  /// so a pass and the run it advises can never be stated at different rates.
  final double dt;

  /// Extra clearance demanded of every survival test.
  final double epsilon;

  final double _cell;
  final double _drift;

  /// Two rolling buffers for the backward recurrence, plus the stored window.
  late final Uint64List _cur = Uint64List(assistMaxRows * _words);
  late final Uint64List _nxt = Uint64List(assistMaxRows * _words);
  late final Uint64List _store =
      Uint64List((assistPreviewFrames + 1) * assistMaxRows * _words);

  /// One row of scratch, for the tap branch that every row shares.
  late final Uint64List _flap = Uint64List(_words);

  /// Per-frame band, as inclusive bit indices, and the lattice origin they are
  /// relative to. Sized for the largest horizon a pass can have.
  final Int32List _bandLo = Int32List(assistMaxFrames + 1);
  final Int32List _bandHi = Int32List(assistMaxFrames + 1);
  final Int32List _origin = Int32List(assistMaxFrames + 1);

  /// How many passes this solver has built. A cost counter, so the price of the
  /// feature can be reported as a measurement rather than an estimate.
  int passes = 0;

  AssistSolver({this.dt = replayFrameSeconds, this.epsilon = assistEpsilon})
    : _cell = GameModel.gravity * dt * dt,
      _drift = GameModel.flapImpulse * dt;

  /// `framesSinceFlap` for a car moving at [velocity], or -1 when that is not a
  /// velocity this game can produce.
  ///
  /// A flap ASSIGNS `flapImpulse` and gravity then adds `gravity * dt` per
  /// frame, so the counter is not extra state to be tracked alongside the model
  /// — it is already in the model, written in the velocity. That is the same
  /// observation `tool/fairness.dart` collapses its state space with.
  ///
  /// The velocity the game holds is a running sum, so it drifts from
  /// `flapImpulse + n * gravity * dt` by a few ulps; rounding recovers the
  /// integer, and the tolerance below rejects anything that is not one — a
  /// velocity from somewhere else entirely, rather than a rounding error.
  int counterFor(double velocity) {
    // Before anything else, because `double.nan.round()` THROWS rather than
    // returning a nonsense integer — so a NaN reaching the arithmetic below
    // would take the game down instead of switching the advice off.
    if (!velocity.isFinite) return -1;
    final double step = GameModel.gravity * dt;
    final double raw = (velocity - GameModel.flapImpulse) / step;
    final int n = raw.round();
    if ((raw - n).abs() > 0.25) return -1;
    if (n < 0 || n >= assistMaxRows) return -1;
    return n;
  }

  /// Builds a pass anchored at [model], which is the state at run frame
  /// [frame].
  ///
  /// Null when there is nothing to advise about: the run is not live, the car is
  /// in a state the search cannot represent, or the world holds no obstacle the
  /// car has yet to pass.
  AssistPlan? plan(GameModel model, int frame) {
    if (model.state != RunState.playing) return null;

    final int baseCounter = counterFor(model.velocity);
    if (baseCounter < 0) return null;

    final AssistWorld world = AssistWorld(model, dt);
    final int target = world.nextUnscoredIndex();
    if (target < 0) return null;

    // -- walk the world forward, banking a band per frame --------------------
    //
    // The horizon runs to the moment the next obstacle can no longer touch the
    // car — the same instant the game awards its point — and then
    // [assistLookaheadFrames] further, so the advice knows where it is leaving
    // the car rather than only that it got past one pipe.
    int last = 0;
    int clearedAt = -1;
    _origin[0] = _originAt(model.y, 0);
    for (int k = 1; k <= assistMaxFrames; k++) {
      world.step();
      _origin[k] = _originAt(model.y, k);
      final Band band = world.aliveBand();
      final int lo = _bitCeil(band.lo + epsilon, model.y, k);
      final int hi = _bitFloor(band.hi - epsilon, model.y, k);
      _bandLo[k] = lo < 0 ? 0 : lo;
      _bandHi[k] = hi > _rowBits - 1 ? _rowBits - 1 : hi;
      if (_bandLo[k] > _bandHi[k]) {
        // Nothing at all can be alive on this frame, so the horizon stops one
        // frame short of it. The shipped game cannot produce such a course —
        // `tool/prove_fairness.dart` certifies that it cannot — so this is a
        // guard against a course nobody has built, not an expected path.
        break;
      }
      last = k;
      if (clearedAt < 0 && world.hasCleared(target)) clearedAt = k;
      if (clearedAt >= 0 && k >= clearedAt + assistLookaheadFrames) break;
    }
    if (last < 1) return null;

    passes++;

    // -- the backward pass ---------------------------------------------------
    final int stored =
        (last < assistPreviewFrames ? last : assistPreviewFrames) + 1;
    final Int32List storedOrigins = Int32List(stored);

    Uint64List next = _nxt;
    Uint64List cur = _cur;

    // ONLY THE ROWS THAT CAN BE OCCUPIED ARE COMPUTED, and this is where most of
    // the cost of a pass went. A counter rises by one per frame and is reset to
    // one by a tap, so from a car whose counter is `baseCounter` now, nothing at
    // frame k can have a counter above `baseCounter + k` — no matter what is
    // tapped in between. Near the start of a pass that is a handful of rows
    // rather than 88, and the rows above are never written and never read.
    int topRow(int k) {
      final int reachable = baseCounter + k;
      return reachable < assistMaxRows - 1 ? reachable : assistMaxRows - 1;
    }

    // Frame `last` is the end of the horizon: anything inside the band there is
    // "survived", because the search does not claim to know what happens after.
    next.fillRange(0, next.length, 0);
    for (int row = 0; row <= topRow(last); row++) {
      _fillRange(next, row * _words, _bandLo[last], _bandHi[last]);
    }
    if (last < stored) {
      _copyFrame(next, _store, last);
      storedOrigins[last] = _origin[last];
    }

    for (int k = last - 1; k >= 0; k--) {
      final int delta = _origin[k + 1] - _origin[k];
      final int top = topRow(k);
      cur.fillRange(0, (top + 1) * _words, 0);

      // A tap takes EVERY row to row 1 of the next frame, so its contribution is
      // identical for every row. Shifted once into a scratch row and then OR-ed
      // in, rather than re-derived on each of them.
      _flap.fillRange(0, _words, 0);
      _orShiftedDown(_flap, 0, next, 1 * _words, 1 - delta);

      for (int row = 0; row <= top; row++) {
        final int off = row * _words;
        // Coasting: the counter goes n -> n + 1 and the position advances by
        // that same n + 1 cells. Row `row + 1` of the next frame is inside its
        // own top row by construction, since topRow(k + 1) is topRow(k) + 1
        // until the clamp bites. At the clamp the top row has no n + 1 to come
        // from and keeps only its tap branch — see [assistMaxRows] for why
        // dropping those states can only make the offer smaller.
        if (row + 1 <= topRow(k + 1)) {
          _orShiftedDown(cur, off, next, (row + 1) * _words, row + 1 - delta);
        }
        for (int w = 0; w < _words; w++) {
          cur[off + w] |= _flap[w];
        }
      }

      // Frame 0 is where the car already is, so it is not filtered: the state it
      // is standing in is alive by definition, and masking it against a band
      // computed for a frame that has already happened would be asking the
      // wrong question.
      if (k >= 1) {
        for (int row = 0; row <= top; row++) {
          _maskToRange(cur, row * _words, _bandLo[k], _bandHi[k]);
        }
      }

      if (k < stored) {
        _copyFrame(cur, _store, k);
        storedOrigins[k] = _origin[k];
      }

      final Uint64List swap = next;
      next = cur;
      cur = swap;
    }

    return AssistPlan._(
      _store,
      storedOrigins,
      this,
      passes,
      baseFrame: frame,
      baseY: model.y,
      storedFrames: stored,
      cell: _cell,
      drift: _drift,
      baseCounter: baseCounter,
    );
  }

  int _originAt(double baseY, int k) =>
      ((GameModel.minY - baseY - k * _drift) / _cell).floor();

  int _bitCeil(double y, double baseY, int k) =>
      ((y - baseY - k * _drift) / _cell).ceil() - _origin[k];

  int _bitFloor(double y, double baseY, int k) =>
      ((y - baseY - k * _drift) / _cell).floor() - _origin[k];

  static void _copyFrame(Uint64List src, Uint64List dst, int frame) {
    final int base = frame * assistMaxRows * _words;
    for (int i = 0; i < src.length; i++) {
      dst[base + i] = src[i];
    }
  }

  /// Sets bits [lo]..[hi] inclusive in one row, and clears the rest.
  static void _fillRange(Uint64List buf, int off, int lo, int hi) {
    for (int w = 0; w < _words; w++) {
      buf[off + w] = 0;
    }
    for (int w = lo >> 6; w <= (hi >> 6); w++) {
      buf[off + w] = -1;
    }
    _maskToRange(buf, off, lo, hi);
  }

  /// Clears every bit outside [lo]..[hi] inclusive in one row.
  static void _maskToRange(Uint64List buf, int off, int lo, int hi) {
    final int wLo = lo >> 6;
    final int wHi = hi >> 6;
    for (int w = 0; w < wLo; w++) {
      buf[off + w] = 0;
    }
    for (int w = wHi + 1; w < _words; w++) {
      buf[off + w] = 0;
    }
    final int loBit = lo & (_wordBits - 1);
    final int hiBit = hi & (_wordBits - 1);
    final int maskLo = loBit == 0 ? -1 : (-1 << loBit);
    final int maskHi = hiBit == 63 ? -1 : ((1 << (hiBit + 1)) - 1);
    if (wLo == wHi) {
      buf[off + wLo] &= maskLo & maskHi;
    } else {
      buf[off + wLo] &= maskLo;
      buf[off + wHi] &= maskHi;
    }
  }

  /// `dst[i] |= src[i + shift]` across one row, for any sign of [shift].
  ///
  /// This is the whole physics step. A state at bit `i` of this frame reaches
  /// bit `i + shift` of the next one, so asking "does my successor survive"
  /// backwards is a shift in the opposite direction — and doing it a word at a
  /// time is what makes a frame of the search 27 operations instead of 1728.
  static void _orShiftedDown(
    Uint64List dst,
    int dOff,
    Uint64List src,
    int sOff,
    int shift,
  ) {
    // Dart's `%` is non-negative for a positive divisor, so this is a floor
    // decomposition and needs no special case for a negative shift.
    final int r = shift % _wordBits;
    final int q = (shift - r) ~/ _wordBits;
    if (r == 0) {
      for (int w = 0; w < _words; w++) {
        final int a = w + q;
        if (a < 0 || a >= _words) continue;
        dst[dOff + w] |= src[sOff + a];
      }
      return;
    }
    final int inv = _wordBits - r;
    for (int w = 0; w < _words; w++) {
      final int a = w + q;
      final int b = a + 1;
      int v = 0;
      if (a >= 0 && a < _words) v |= src[sOff + a] >>> r;
      if (b >= 0 && b < _words) v |= src[sOff + b] << inv;
      if (v != 0) dst[dOff + w] |= v;
    }
  }
}

/// The band of car centres that survive one frame: a single closed interval.
///
/// PUBLIC, like [AssistWorld], so a test can compare it against the collision
/// rule in `GameModel.tick` directly rather than only through a plan.
class Band {
  /// Lowest surviving y, inclusive.
  final double lo;

  /// Highest surviving y, inclusive.
  final double hi;

  const Band(this.lo, this.hi);

  /// True when nothing at all survives this frame.
  bool get isEmpty => lo > hi;
}

/// The obstacle half of `GameModel.tick`, run without a car.
///
/// WHY THIS EXISTS RATHER THAN TICKING A `GameModel`: a model ticked forward
/// also moves and eventually KILLS a car, and a dead model freezes — `tick`
/// returns the receiver — so the pipes would stop moving the moment the
/// hypothetical car hit one. The search needs the world's timeline
/// independently of any car, which is exactly the separation
/// `tool/fairness.dart` is built on: obstacles move, are dropped, and spawn
/// without ever reading the car's y.
///
/// It is a SECOND COPY of the game's spawn cadence, and that is a real risk — a
/// copy that drifted would advise about a course the player is not on.
/// `test/assist_test.dart` pins it to a live `GameModel` obstacle for obstacle,
/// frame for frame, rather than trusting this comment — which is the only reason
/// this class and [Band] are public rather than private to the solver.
class AssistWorld {
  final GapPattern pattern;
  final double dt;
  final List<Obstacle> _live;
  int _nextIndex;
  int _score;

  AssistWorld(GameModel model, this.dt)
    : pattern = model.gapCentreFor,
      _live = List<Obstacle>.of(model.obstacles),
      _nextIndex = model.nextObstacleIndex,
      _score = model.score;

  /// The obstacles on the playfield right now, left-most first.
  List<Obstacle> get obstacles => _live;

  /// Obstacles that have gone fully behind the car so far. The number
  /// `GameModel` calls `score`, and the ramp's input.
  int get score => _score;

  /// The index of the first obstacle on the playfield that has not scored, or
  /// -1 when there is none.
  int nextUnscoredIndex() {
    for (final Obstacle o in _live) {
      if (!o.scored) return o.index;
    }
    return -1;
  }

  /// True once obstacle [index] can no longer touch the car.
  bool hasCleared(int index) {
    for (final Obstacle o in _live) {
      if (o.index == index) return o.scored;
    }
    // Gone from the playfield entirely, so it went past long ago.
    return true;
  }

  Obstacle _spawnAt(double x, int index) => Obstacle(
    index: index,
    x: x,
    width: GameModel.obstacleWidth,
    gapCentre: GameModel.clampGapCentre(pattern(index)),
    gapHeight: Difficulty.gapHeightAt(index),
  );

  /// One frame, in the same order and off the same numbers as `GameModel.tick`:
  /// scroll at LAST frame's score, move and drop, spawn at most one, then score.
  void step() {
    final double travel = Difficulty.scrollSpeedAt(_score) * dt;
    final List<Obstacle> next = <Obstacle>[];
    for (final Obstacle o in _live) {
      final Obstacle moved = o.movedBy(-travel);
      if (moved.right >= playfieldLeft) next.add(moved);
    }
    if (next.isEmpty) {
      next.add(_spawnAt(playfieldRight, _nextIndex));
      _nextIndex++;
    } else {
      final double spacing = Difficulty.spacingAt(_nextIndex);
      if (next.last.x <= playfieldRight - spacing) {
        next.add(_spawnAt(next.last.x + spacing, _nextIndex));
        _nextIndex++;
      }
    }
    final double carLeft = GameModel.carX - GameModel.carWidth / 2;
    for (int i = 0; i < next.length; i++) {
      final Obstacle o = next[i];
      if (!o.scored && o.right < carLeft) {
        next[i] = o.markScored();
        _score++;
      }
    }
    _live
      ..clear()
      ..addAll(next);
  }

  /// The car centres that survive the current frame.
  ///
  /// Derived the same way `aliveBand` in `tool/fairness.dart` derives it, and
  /// for the same reason it is an interval: an obstacle straddling the car
  /// forbids everything outside `gapTop + carHeight/2 .. gapBottom -
  /// carHeight/2`, intersecting intervals leaves an interval, and the playfield
  /// is an interval too.
  Band aliveBand() {
    final double carLeft = GameModel.carX - GameModel.carWidth / 2;
    final double carRight = GameModel.carX + GameModel.carWidth / 2;
    final double half = GameModel.carHeight / 2;

    double lo = GameModel.minY;
    double hi = GameModel.maxY;
    for (final Obstacle o in _live) {
      // Strict, matching `Box.overlaps`: sharing exactly one edge is not a hit,
      // so an obstacle constrains y only while it genuinely straddles the car.
      if (!(carLeft < o.right && carRight > o.left)) continue;
      final double oLo = o.gapTop + half;
      final double oHi = o.gapBottom - half;
      if (oLo > lo) lo = oLo;
      if (oHi < hi) hi = oHi;
    }
    return Band(lo, hi);
  }
}
