/// The fairness prover: decide whether a **perfect** player could clear a
/// course, by searching the reachable state space rather than by trying policies.
///
/// ============================================================================
/// WHY SAMPLING CANNOT ANSWER THIS QUESTION
/// ============================================================================
///
/// The obvious approach is to write a good bot, run it on the course, and see
/// whether it survives. That approach can only ever prove ONE of the two
/// answers. If the bot survives, the course is definitely survivable — the run
/// is the proof. If the bot dies, we have learned nothing at all: maybe the
/// course is impossible, maybe the bot is bad. Trying a thousand random or
/// heuristic policies does not fix it, because a thousand failures is still
/// "none of the policies I happened to think of worked", which is a statement
/// about the policies. Reporting that as "this course is unfair" would be a
/// guess wearing a number.
///
/// So the prover does the opposite. It never picks a policy. It tracks the SET
/// of every state a player could possibly be in, advances the whole set one
/// frame at a time, and deletes the states that die. If the set is ever empty,
/// then every input sequence — including the ones nobody would think of — is
/// dead by that frame, and the course is genuinely unsurvivable. That is a
/// proof, not a sample.
///
/// ============================================================================
/// WHY THE STATE IS (y, framesSinceFlap) AND NOT (y, velocity)
/// ============================================================================
///
/// A flap ASSIGNS velocity: `velocity = flapImpulse`, never `+=`. (See the long
/// comment on `GameModel.flap`.) So immediately after any flap the velocity is
/// exactly `flapImpulse`, whatever it was a moment earlier, and from there
/// gravity adds exactly `gravity * dt` per frame. Therefore
///
///     velocity = flapImpulse + framesSinceFlap * gravity * dt
///
/// — velocity is not a free variable at all. It is a small counter. That single
/// property is what collapses a continuous two-dimensional state space into
/// something a computer can enumerate exhaustively.
///
/// ============================================================================
/// WHY THE y GRID IS EXACT RATHER THAN APPROXIMATE
/// ============================================================================
///
/// Push the same observation one step further. Write `n_k` for the value of
/// framesSinceFlap after frame k. The position update is
///
///     y_k = y_{k-1} + (flapImpulse + n_k * gravity * dt) * dt
///
/// so after T frames
///
///     y_T = startY + T * (flapImpulse * dt) + (gravity * dt^2) * S,
///           where S = n_1 + n_2 + ... + n_T   is an INTEGER.
///
/// Every reachable position at frame T therefore lies on a lattice: a fixed
/// per-frame offset plus an integer number of steps of size
///
///     cell = gravity * dt^2 = 2.2 / 3600 = 6.1111e-4 playfield-heights.
///
/// This is the grid resolution, and it is not a choice — it is the spacing the
/// physics itself produces. Two consequences matter:
///
///   1. **Nothing is lost to rounding.** A successor of a lattice point is
///      another lattice point exactly, because S only ever grows by the integer
///      n_k. The search stores (S, n) as two integers and never rounds a
///      position at all, so the usual "quantisation might step over a collision"
///      hazard does not arise. For scale, the task's yardstick — the largest
///      single-frame movement, |flapImpulse * dt| = 0.012 — is 19.6 times
///      COARSER than this cell, so a grid at that size really would be able to
///      jump a pipe lip. This one cannot.
///
///   2. **The set is small.** y is confined to [0, 1], so S spans at most
///      1/cell = 1637 values, and framesSinceFlap cannot exceed about 80 before
///      the car has fallen out of the playfield. Around 130,000 states per frame
///      worst case, and the implementation packs the whole thing into bitmaps.
///
/// ============================================================================
/// WHICH WAY THE REMAINING APPROXIMATION ERRS, AND WHY THAT DIRECTION
/// ============================================================================
///
/// The lattice is exact in real arithmetic. It is not bit-identical to the game,
/// because the game accumulates y by repeated addition and this file evaluates a
/// closed form; the two differ by floating-point noise on the order of 1e-13.
///
/// So every survival test is tightened by [defaultEpsilon] = 1e-9 — four orders
/// of magnitude more than that noise, and six orders finer than one lattice
/// cell. The car must clear a pipe by 1e-9 to count as having cleared it.
///
/// That is deliberately the PESSIMISTIC direction. The prover can therefore call
/// a survivable course unsurvivable (you go and look, find the margin was
/// 5e-10, and loosen the epsilon), but it cannot call an unsurvivable course
/// survivable. Getting that backwards is the failure that matters: a prover that
/// certifies an impossible course ships an impossible course.
///
/// ============================================================================
/// WHAT THIS FILE DOES *NOT* MODEL
/// ============================================================================
///
/// Collision here is checked once per frame, at the position the car lands on —
/// exactly like `GameModel.tick`. It is not a swept/continuous test. That is
/// correct rather than sloppy: the shipped game is a discrete simulation, and
/// the prover's job is to prove things about the shipped game, not about an
/// idealised continuous one.
///
/// Pure Dart, no Flutter: runs under `dart run` and under `flutter test`.
library;

import 'dart:typed_data';

import 'package:flappymiata/game/course_seed.dart';
import 'package:flappymiata/game/game_model.dart';

/// The frame the prover and the game both step at.
const double defaultDt = 1.0 / 60.0;

/// How much clearance a state must have to count as alive. See the header: this
/// is the pessimistic slack that absorbs floating-point noise.
const double defaultEpsilon = 1e-9;

// =============================================================================
// Courses
// =============================================================================

/// One obstacle's gap, as a pair of numbers the prover can reason about.
///
/// Separate from [Obstacle] because the prover has to be able to describe gaps
/// the shipped game cannot produce — a gap narrower than the car, a gap sitting
/// outside the playfield — in order to check that it can still say "no". See
/// `tool/prove_fairness.dart`, which builds exactly those.
class CourseGap {
  /// Centre of the gap, in normalised y.
  final double centre;

  /// Height of the gap, in normalised y.
  final double height;

  const CourseGap(this.centre, this.height);

  /// The bottom lip of the upper pipe.
  double get top => centre - height / 2;

  /// The top lip of the lower pipe.
  double get bottom => centre + height / 2;

  @override
  String toString() =>
      'gap(centre: ${centre.toStringAsFixed(4)}, '
      'height: ${height.toStringAsFixed(4)})';
}

/// How fast the world moves and how far apart the obstacles stand — the two
/// parts of a course that are NOT properties of a single obstacle.
///
/// WHY THIS IS AN OBJECT RATHER THAN TWO NUMBERS ON [Course]: the shipped game
/// ramps both with progress (see `Difficulty` in `lib/game/game_model.dart`),
/// so "the spacing" and "the scroll speed" stopped being single values. The
/// prover has to be able to describe a course whose speed and spacing change
/// under it, or it would be proving things about a game nobody ships — which is
/// the one failure mode of a prover that matters.
///
/// Both quantities are functions of PROGRESS and of nothing else. Neither reads
/// a clock, and neither reads the car's position — which is what keeps the world
/// timeline independent of the player and therefore enumerable as a fixed
/// backdrop. See [CourseWorld].
abstract class CourseDifficulty {
  const CourseDifficulty();

  /// Scroll speed to use on a frame that begins with [obstaclesCleared]
  /// obstacles already behind the car.
  ///
  /// The argument is the count as of the END of the previous frame, because
  /// that is exactly what `GameModel.tick` has to hand: it reads `this.score`,
  /// which this frame's scoring has not yet touched.
  double scrollSpeedAfter(int obstaclesCleared);

  /// Distance placed between obstacle [obstacleIndex] and the one before it.
  double spacingBefore(int obstacleIndex);
}

/// The pre-ramp world: one speed and one spacing, for ever.
///
/// This is what every hand-built falsification course wants — a course designed
/// to be impossible for one specific reason should not also be moving under the
/// prover — and it is also how a candidate plateau setting gets measured in
/// isolation before it is written into the ramp.
class FixedDifficulty extends CourseDifficulty {
  /// Playfield-widths per second.
  final double scrollSpeed;

  /// Playfield-widths between consecutive obstacles.
  final double spacing;

  const FixedDifficulty({
    this.scrollSpeed = GameModel.scrollSpeed,
    this.spacing = GameModel.obstacleSpacing,
  });

  @override
  double scrollSpeedAfter(int obstaclesCleared) => scrollSpeed;

  @override
  double spacingBefore(int obstacleIndex) => spacing;
}

/// The shipped ramp, evaluated at the course's own depth in the run.
///
/// [firstIndex] is the ABSOLUTE obstacle index of the course's first gap. It has
/// to be carried, because the ramp is a function of how far into a run the
/// player is and a window taken from obstacle 4000 is at obstacle 4000's
/// difficulty — reading the ramp at the window's LOCAL index 0 would prove the
/// easy start of the game over and over and call it a proof about the whole of
/// it.
///
/// This calls straight into `Difficulty`, the same functions `GameModel.tick`
/// calls. There is no second copy of the ramp arithmetic to drift.
class RampedDifficulty extends CourseDifficulty {
  /// Absolute obstacle index of the course's first gap.
  final int firstIndex;

  const RampedDifficulty(this.firstIndex);

  @override
  double scrollSpeedAfter(int obstaclesCleared) =>
      Difficulty.scrollSpeedAt(firstIndex + obstaclesCleared);

  @override
  double spacingBefore(int obstacleIndex) =>
      Difficulty.spacingAt(firstIndex + obstacleIndex);
}

/// A finite sequence of obstacles, plus the speed and spacing they are laid out
/// at.
///
/// A course is "cleared" when the last obstacle's right edge has passed the
/// car's left edge — the same instant the game awards its point, and the instant
/// after which that obstacle can never collide again.
class Course {
  /// A label for reports.
  final String name;

  /// The gaps, in the order the car meets them.
  final List<CourseGap> gaps;

  /// Where the world's speed and spacing come from. See [CourseDifficulty].
  final CourseDifficulty difficulty;

  /// The absolute obstacle index of `gaps[0]`, for reports.
  final int firstIndex;

  /// True when this course is something the shipped game can actually produce
  /// FROM A FRESH START — the real gap heights, the real ramp, centres from a
  /// real pattern, beginning at obstacle 0. Only these courses can have a
  /// witness replayed through the real [GameModel].
  ///
  /// WHY IT IS NOT ENOUGH THAT THE PATTERN IS REAL, which it was before the
  /// ramp arrived: a window taken from obstacle 4000 is proved at obstacle
  /// 4000's speed, spacing and gap height, and a fresh `GameModel` starts at
  /// obstacle 0's. Replaying such a witness through the game would run it
  /// against an EASIER course than the one that was proved, and it would pass
  /// while checking nothing.
  final bool playableByGame;

  /// [spacing] is a shorthand for `difficulty: FixedDifficulty(spacing: ...)`,
  /// kept because every falsification course in the suite is stated in terms of
  /// it: "the same two gaps, 0.20 apart" is the whole content of those courses.
  /// Passing [difficulty] overrides it.
  ///
  /// Not `const` any more, and it cannot be: the default difficulty has to be
  /// built out of the [spacing] argument, which is not a compile-time constant.
  /// Nothing constructed one at compile time.
  Course({
    required this.name,
    required this.gaps,
    double spacing = GameModel.obstacleSpacing,
    CourseDifficulty? difficulty,
    this.firstIndex = 0,
    this.playableByGame = false,
  }) : difficulty = difficulty ?? FixedDifficulty(spacing: spacing);

  /// The stretch of the course produced by [pattern], starting at obstacle
  /// [firstIndex] and running for [count] obstacles.
  ///
  /// Centres are put through [GameModel.clampGapCentre] — the same call
  /// `GameModel._spawnAt` makes — and gap heights come from
  /// [Difficulty.gapHeightAt] at the same absolute index the game would use, so
  /// the result is the course the game really produces at that depth.
  ///
  /// WHY THIS TAKES A PATTERN RATHER THAN ONLY KNOWING ABOUT THE SHIPPED ONE:
  /// the daily challenge is a second course generator, and it has to be held to
  /// exactly the same fairness bar as the first. Making the prover able to take
  /// any pattern is what stops there being a second prover for the second
  /// generator — one prover, two inputs, one standard of evidence.
  factory Course.fromPattern(
    String name,
    GapPattern pattern,
    int firstIndex,
    int count,
  ) => Course(
    name: name,
    gaps: List<CourseGap>.generate(
      count,
      (int k) => CourseGap(
        GameModel.clampGapCentre(pattern(firstIndex + k)),
        Difficulty.gapHeightAt(firstIndex + k),
      ),
    ),
    difficulty: RampedDifficulty(firstIndex),
    firstIndex: firstIndex,
    playableByGame: firstIndex == 0,
  );

  /// The stretch of the shipped game's own course starting at obstacle
  /// [firstIndex] and running for [count] obstacles.
  factory Course.fromDefaultPattern(int firstIndex, int count) =>
      Course.fromPattern(
        'default[$firstIndex..${firstIndex + count - 1}]',
        GameModel.defaultGapCentre,
        firstIndex,
        count,
      );

  /// The stretch of the course selected by [seed]. Seed 0 is the shipped
  /// course, so `Course.fromSeed(0, a, b)` and
  /// `Course.fromDefaultPattern(a, b)` are the same course.
  factory Course.fromSeed(int seed, int firstIndex, int count) =>
      Course.fromPattern(
        'seed $seed [$firstIndex..${firstIndex + count - 1}]',
        gapPatternForSeed(seed),
        firstIndex,
        count,
      );

  /// The gap pattern that reproduces this course inside a real [GameModel].
  ///
  /// Only meaningful when [playableByGame]; used to replay a witness.
  GapPattern get asGapPattern =>
      (int index) => index < gaps.length ? gaps[index].centre : 0.5;
}

// =============================================================================
// The world timeline
// =============================================================================

/// One obstacle as the prover sees it: where it is and what it blocks.
class WorldObstacle {
  /// Index into the course's gap list.
  final int index;

  /// Centre x, in playfield-widths.
  final double x;

  /// The gap this obstacle leaves open.
  final CourseGap gap;

  const WorldObstacle(this.index, this.x, this.gap);

  /// Left edge.
  double get left => x - GameModel.obstacleWidth / 2;

  /// Right edge.
  double get right => x + GameModel.obstacleWidth / 2;
}

/// The obstacle half of `GameModel.tick`, replayed on its own.
///
/// WHY THIS CAN BE SEPARATED FROM THE PLAYER AT ALL — this is the observation the
/// whole search rests on:
///
/// obstacles move by `scrollSpeed * dt` every frame, are dropped when their right
/// edge passes the left wall, and spawn on a cadence measured from the newest
/// obstacle. Not one of those three rules reads the car's y or its velocity.
/// **The world at frame T is therefore the same whatever the player does.**
/// That is what lets the search treat "the pipes at frame T" as a fixed backdrop
/// and enumerate only the car's states against it.
///
/// THE RAMP DOES NOT BREAK THAT, and it is worth spelling out why, because at
/// first glance it looks as though it must: the scroll speed now depends on the
/// SCORE, and the score is surely something the player earns. It is not. An
/// obstacle scores when its right edge passes the car's left edge — a fact about
/// where the pipe is, not about where the car is or how well it was flown. Every
/// state alive at frame T has therefore passed exactly the same obstacles, so
/// the score at frame T is a property of the world, the ramp reads a number the
/// world already knows, and the backdrop stays fixed.
///
/// This duplicates logic that lives in `GameModel.tick`, which is a real risk:
/// if the game's spawn cadence changed and this did not, the prover would be
/// proving things about a game nobody ships. `test/fairness_prover_test.dart`
/// pins the two together frame by frame against a live [GameModel] run.
class CourseWorld {
  /// The course being laid out.
  final Course course;

  /// Seconds per frame.
  final double dt;

  final List<WorldObstacle> _live = <WorldObstacle>[];
  int _nextIndex = 0;
  int _frame = 0;

  /// Obstacles behind the car as of the END of the previous frame.
  ///
  /// Held rather than recomputed at the top of [step] because that is what the
  /// game has: `GameModel.tick` scrolls the world using `this.score`, which is
  /// last frame's answer — this frame's points have not been awarded yet. A
  /// world that used THIS frame's count would be one frame ahead of the game on
  /// every ramp step, and the two would drift apart by a fraction of a pixel
  /// per obstacle for as long as a run lasted.
  ///
  /// IT IS A CACHE, AND READING [clearedSoFar] AT THE TOP OF [step] WOULD GIVE
  /// THE SAME ANSWER — which is worth writing down, because it means no test can
  /// tell the two spellings apart and somebody will eventually "fix" one into
  /// the other. The argument: this field is assigned at the END of `step` from
  /// `clearedSoFar`, and `_live` and `_nextIndex` are private and written
  /// nowhere else, so nothing can change between that assignment and the top of
  /// the next `step`. The equality is by construction rather than by
  /// coincidence. The field is kept because it names WHICH frame's count the
  /// scroll speed is read from, and that is the fact a reader has to be able to
  /// check against `GameModel.tick`.
  int _clearedLastFrame = 0;

  CourseWorld(this.course, {this.dt = defaultDt});

  /// Frames stepped so far. Frame 0 is the state before the first tick, when the
  /// playfield is bare.
  int get frame => _frame;

  /// The obstacles on the playfield right now, left-most first.
  List<WorldObstacle> get obstacles => _live;

  /// Gap data for obstacle [index].
  ///
  /// Past the end of the course the world keeps spawning on cadence — the game
  /// would — but with a gap taller than the playfield, so those obstacles cannot
  /// constrain anything. They exist only to keep the spawn timing of the
  /// obstacles that DO matter identical to the game's.
  CourseGap _gapFor(int index) =>
      index < course.gaps.length ? course.gaps[index] : const CourseGap(0.5, 2.0);

  /// Advances the world one frame. Mirrors `GameModel.tick` exactly: move and
  /// drop first, then spawn at most one new obstacle.
  void step() {
    final double travel =
        course.difficulty.scrollSpeedAfter(_clearedLastFrame) * dt;
    final List<WorldObstacle> next = <WorldObstacle>[];
    for (final WorldObstacle o in _live) {
      final WorldObstacle moved = WorldObstacle(o.index, o.x - travel, o.gap);
      if (moved.right >= playfieldLeft) next.add(moved);
    }
    if (next.isEmpty) {
      next.add(
        WorldObstacle(_nextIndex, playfieldRight, _gapFor(_nextIndex)),
      );
      _nextIndex++;
    } else {
      // Read once and reused for both the test and the placement, exactly as
      // `GameModel.tick` does. Two calls would be two chances for the ramp to
      // be sampled at different arguments.
      final double spacing = course.difficulty.spacingBefore(_nextIndex);
      if (next.last.x <= playfieldRight - spacing) {
        next.add(
          WorldObstacle(_nextIndex, next.last.x + spacing, _gapFor(_nextIndex)),
        );
        _nextIndex++;
      }
    }
    _live
      ..clear()
      ..addAll(next);
    _frame++;
    _clearedLastFrame = clearedSoFar;
  }

  /// How many obstacles have gone fully behind the car, NOT capped by the
  /// length of the course.
  ///
  /// Counted from the left-most obstacle still alive: everything with a smaller
  /// index has already been dropped, and dropping happens long after passing.
  ///
  /// This is the number the game calls `score`, and it is the ramp's input, so
  /// it must not be capped: past the end of a short course the world keeps
  /// spawning on cadence, and capping here would freeze the ramp at a difficulty
  /// the game would have moved on from.
  int get clearedSoFar {
    final double carLeft = GameModel.carX - GameModel.carWidth / 2;
    int cleared = _nextIndex;
    for (final WorldObstacle o in _live) {
      if (o.right >= carLeft && o.index < cleared) cleared = o.index;
    }
    return cleared;
  }

  /// How many of the COURSE's obstacles have gone fully behind the car.
  int get obstaclesCleared {
    final int cleared = clearedSoFar;
    return cleared > course.gaps.length ? course.gaps.length : cleared;
  }

  /// True once the last obstacle of the course can no longer touch the car.
  bool get courseCleared => obstaclesCleared >= course.gaps.length;
}

// =============================================================================
// The alive band
// =============================================================================

/// Why no state could survive a frame.
enum FailureCause {
  /// A single obstacle's gap is too short to admit the car at all. Nothing about
  /// flying causes this; the geometry is impossible on its own.
  gapNarrowerThanCar,

  /// A single obstacle's gap admits the car, but only at a y outside the
  /// playfield — so threading it means dying to the out-of-bounds rule instead.
  gapOutsidePlayfield,

  /// Two obstacles overlap the car at the same moment and their gaps do not
  /// share a single y. Only possible when the spacing is smaller than the car
  /// plus a pipe.
  overlappingGapsDisjoint,

  /// Every obstacle on screen is individually flyable and the playfield is not
  /// the problem — but no state the car could actually be in is inside the
  /// legal band. This is the interesting one: the course is defeated by the
  /// PHYSICS, not by the geometry.
  unreachable,

  /// The search hit its frame budget without clearing the course. Not a proof of
  /// anything; reported so it can never be mistaken for one.
  frameBudget,
}

/// The set of car centres that survive one frame — always a single closed
/// interval.
///
/// WHY AN INTERVAL AND NOT AN ARBITRARY SET: an obstacle is two boxes with a gap
/// between them, and the car is a box of fixed height. Working the AABB test
/// through (`Box.overlaps`, plus the fact that the car is inside the playfield
/// so it always overlaps both pipes vertically at the extremes) leaves exactly
///
///     gapTop + carHeight/2  <=  y  <=  gapBottom - carHeight/2
///
/// for each obstacle that overlaps the car horizontally. Intersecting intervals
/// gives an interval, and intersecting with the playfield gives an interval. So
/// "which positions are legal this frame" is two numbers, computed in a handful
/// of operations — which is what makes 800,000-frame searches affordable.
class AliveBand {
  /// Lowest surviving y (inclusive).
  final double lo;

  /// Highest surviving y (inclusive).
  final double hi;

  /// Set when the band is empty, saying which geometry closed it.
  final FailureCause? cause;

  const AliveBand(this.lo, this.hi, this.cause);

  /// True when nothing survives this frame.
  bool get isEmpty => lo > hi;
}

/// The band of legal car centres against [obstacles], demanding [inflate] extra
/// clearance from every pipe.
///
/// [inflate] is what makes a margin measurable: re-running the whole proof with
/// a fatter car and asking whether it still fits is the same as asking how much
/// room the best path ever had to spare.
AliveBand aliveBand(List<WorldObstacle> obstacles, double inflate) {
  final double carLeft = GameModel.carX - GameModel.carWidth / 2;
  final double carRight = GameModel.carX + GameModel.carWidth / 2;
  final double half = GameModel.carHeight / 2;

  double lo = GameModel.minY;
  double hi = GameModel.maxY;
  FailureCause? cause;
  int overlapping = 0;

  for (final WorldObstacle o in obstacles) {
    // Strict comparisons, matching `Box.overlaps`: sharing exactly one edge is
    // not a hit, so an obstacle only constrains y while it genuinely straddles
    // the car horizontally.
    if (!(carLeft < o.right && carRight > o.left)) continue;
    overlapping++;

    final double oLo = o.gap.top + half + inflate;
    final double oHi = o.gap.bottom - half - inflate;

    if (oLo > oHi) {
      cause ??= FailureCause.gapNarrowerThanCar;
    } else if (oHi < GameModel.minY || oLo > GameModel.maxY) {
      // The gap is wide enough for the car, but the only place the car fits is
      // off the playfield — where the bounds rule kills it.
      cause ??= FailureCause.gapOutsidePlayfield;
    }

    if (oLo > lo) lo = oLo;
    if (oHi < hi) hi = oHi;
  }

  if (lo > hi && cause == null && overlapping >= 2) {
    cause = FailureCause.overlappingGapsDisjoint;
  }
  return AliveBand(lo, hi, cause);
}

// =============================================================================
// The proof
// =============================================================================

/// What one proof attempt found.
class ProofResult {
  /// True when some input sequence clears the whole course.
  final bool survivable;

  /// Frames the search ran for.
  final int frames;

  /// Obstacles of the course that were cleared before the search stopped.
  final int obstaclesCleared;

  /// The frame the reachable set went empty, when it did.
  final int? deathFrame;

  /// Which obstacle the car was working on when the set went empty.
  final int? deathObstacleIndex;

  /// Why the set went empty. Null when the course was cleared.
  final FailureCause? cause;

  /// Largest number of (position, framesSinceFlap) pairs alive at once. A
  /// sanity figure: it is the size of the thing that was actually enumerated.
  final int peakStates;

  /// A surviving input sequence, when one was asked for. One bool per frame,
  /// feedable straight to `replay` in `tool/headless_sim.dart`.
  final List<bool>? witness;

  const ProofResult({
    required this.survivable,
    required this.frames,
    required this.obstaclesCleared,
    required this.peakStates,
    this.deathFrame,
    this.deathObstacleIndex,
    this.cause,
    this.witness,
  });

  @override
  String toString() => survivable
      ? 'SURVIVABLE after $frames frames (peak $peakStates states)'
      : 'UNSURVIVABLE at frame $deathFrame, obstacle $deathObstacleIndex, '
            'cause ${cause?.name}';
}

/// Bit width of one machine word in the reachable-set bitmaps.
const int _wordBits = 64;

/// Words per position-bitmap row.
///
/// A row has to span the whole playfield in lattice cells: 1 / cell = 1637 of
/// them, plus a little slack for where the per-frame lattice origin is rounded.
/// 27 * 64 = 1728 bits covers it with room to spare.
const int _words = 27;

/// The reachability prover.
///
/// One instance is reusable across courses; it allocates its bitmaps once.
class FairnessProver {
  /// Seconds per frame.
  final double dt;

  /// Extra clearance demanded of every survival test. Pessimistic on purpose.
  final double epsilon;

  /// Largest framesSinceFlap the search will represent.
  ///
  /// Physically about 80 is the ceiling — a car falling that long from any
  /// legal height has already left the playfield — so 160 is generous. It is a
  /// GUARD, not a tuning knob: if a state ever reaches the last row, the search
  /// throws rather than silently dropping reachable states, because silently
  /// dropping states is how a prover starts reporting fair courses as unfair.
  final int maxCounter;

  /// One lattice cell: `gravity * dt^2`. The exact spacing of reachable
  /// positions. See the header.
  final double cell;

  /// How far the lattice origin slides per frame: `flapImpulse * dt`.
  final double drift;

  /// How many reachability searches this instance has run. Reported by the
  /// tool so the cost of an answer is visible rather than estimated.
  int proveCalls = 0;

  late final Uint64List _cur = Uint64List((maxCounter + 1) * _words);
  late final Uint64List _nxt = Uint64List((maxCounter + 1) * _words);
  late final Uint64List _union = Uint64List(_words);

  FairnessProver({
    double dt = defaultDt,
    this.epsilon = defaultEpsilon,
    this.maxCounter = 160,
  }) : dt = dt,
       cell = GameModel.gravity * dt * dt,
       drift = GameModel.flapImpulse * dt {
    // A row has to be able to hold every legal position at once. Nothing about
    // the derivation needs dt = 1/60, but a much smaller dt would need a wider
    // row, and silently running off the end of one would drop reachable states.
    final int slots = ((GameModel.maxY - GameModel.minY) / cell).ceil() + 4;
    if (slots > _words * _wordBits) {
      throw ArgumentError(
        'dt = $dt needs $slots lattice slots but a row holds '
        '${_words * _wordBits}; widen _words',
      );
    }
  }

  /// The y of lattice point [s] at frame [frame].
  ///
  /// This is the closed form from the header — a single multiply-add rather than
  /// `frame` accumulated additions — which is exactly why the search never
  /// accumulates rounding error no matter how long the course is.
  double yAt(int frame, int s) => GameModel.startY + frame * drift + cell * s;

  /// The lattice index whose y is the bottom of the playfield at [frame]. Bit 0
  /// of every row means this index, so the whole reachable set fits in a window
  /// that slides with the car's average drift.
  int originAt(int frame) =>
      ((GameModel.minY - GameModel.startY - frame * drift) / cell).floor();

  /// Proves — or refutes — that [course] can be cleared.
  ///
  /// [inflate] fattens the car against every pipe by that much on each side;
  /// [tightestMargin] bisects on it to measure how much room the best path had.
  ///
  /// [witness] asks for a surviving input sequence to be recovered. It costs one
  /// snapshot of the bitmaps per frame, so it is off by default.
  ProofResult prove(
    Course course, {
    double inflate = 0.0,
    bool witness = false,
    int maxFrames = 2000000,
  }) {
    proveCalls++;
    final CourseWorld world = CourseWorld(course, dt: dt);

    final Uint64List cur = _cur..fillRange(0, _cur.length, 0);
    final Uint64List nxt = _nxt;
    Uint64List src = cur;
    Uint64List dst = nxt;

    // Frame 0. The run has just left `ready`, which it can only do by flapping,
    // so velocity is exactly flapImpulse and framesSinceFlap is 0. Waiting
    // before that first tap is a no-op — `tick` returns the receiver unchanged
    // while the state is `ready` — so starting the clock here loses no options.
    int origin = originAt(0);
    int startBit = 0 - origin;
    src[startBit >> 6] = 1 << (startBit & (_wordBits - 1));
    int rowMin = 0;
    int rowMax = 0;
    int validLo = startBit >> 6;
    int validHi = startBit >> 6;
    int peak = 1;

    // Snapshots for witness recovery, one per frame, plus the lattice origin
    // that each frame's bit indices are relative to.
    final List<Uint64List>? tape = witness ? <Uint64List>[] : null;
    final List<int>? origins = witness ? <int>[] : null;
    final List<int>? rowTops = witness ? <int>[] : null;
    if (tape != null) {
      tape.add(_snapshot(src, validLo, validHi));
      origins!.add(origin);
      rowTops!.add(rowMax);
    }

    int frame = 0;
    while (frame < maxFrames) {
      world.step();
      final int nextFrame = frame + 1;

      final AliveBand band = aliveBand(world.obstacles, inflate);
      if (band.isEmpty) {
        return _dead(world, nextFrame, band.cause ?? FailureCause.unreachable,
            peak);
      }

      final int nextOrigin = originAt(nextFrame);
      final int delta = nextOrigin - origin;

      // The band, shrunk by epsilon on both sides (the pessimistic direction),
      // converted to the inclusive range of lattice indices it admits.
      final int sLo =
          ((band.lo + epsilon - GameModel.startY - nextFrame * drift) / cell)
              .ceil();
      final int sHi =
          ((band.hi - epsilon - GameModel.startY - nextFrame * drift) / cell)
              .floor();
      int iLo = sLo - nextOrigin;
      int iHi = sHi - nextOrigin;
      if (iLo < 0) iLo = 0;
      if (iHi > _words * _wordBits - 1) iHi = _words * _wordBits - 1;
      if (iLo > iHi) {
        // The legal band is real but narrower than the distance between two
        // reachable positions, so nothing can be inside it.
        return _dead(world, nextFrame, FailureCause.unreachable, peak);
      }

      final int wLo = iLo >> 6;
      final int wHi = iHi >> 6;

      if (rowMax + 1 > maxCounter) {
        throw StateError(
          'framesSinceFlap reached the $maxCounter row cap at frame $nextFrame; '
          'raise maxCounter — dropping these states would make the prover '
          'unsound in the direction that matters',
        );
      }
      final int newRowMax = rowMax + 1;

      // Clear only the destination rows and only the words the band can occupy.
      // Everything outside [wLo, wHi] is left stale on purpose and is never
      // read: `validLo`/`validHi` record which words of a buffer mean anything.
      for (int r = 1; r <= newRowMax; r++) {
        final int off = r * _words;
        for (int w = wLo; w <= wHi; w++) {
          dst[off + w] = 0;
        }
      }

      // -- branch one: flap ---------------------------------------------------
      //
      // A flap resets framesSinceFlap to 1 whatever it was, so EVERY live row
      // feeds the same destination row. Union them once and shift once, instead
      // of shifting each row separately into the same place.
      for (int w = validLo; w <= validHi; w++) {
        _union[w] = 0;
      }
      for (int r = rowMin; r <= rowMax; r++) {
        final int off = r * _words;
        for (int w = validLo; w <= validHi; w++) {
          _union[w] |= src[off + w];
        }
      }
      // S grows by the new counter (1), and the window origin moves by delta.
      _orShifted(dst, _words, _union, 0, 1 - delta, wLo, wHi, validLo, validHi);

      // -- branch two: don't flap --------------------------------------------
      //
      // framesSinceFlap goes n -> n+1 and S grows by that same n+1. One shift
      // per row, and the shift amount is what encodes the physics.
      for (int r = rowMin; r <= rowMax; r++) {
        _orShifted(dst, (r + 1) * _words, src, r * _words, r + 1 - delta, wLo,
            wHi, validLo, validHi);
      }

      // -- kill everything outside the band ----------------------------------
      final int loBit = iLo & (_wordBits - 1);
      final int hiBit = iHi & (_wordBits - 1);
      final int maskLo = loBit == 0 ? -1 : (-1 << loBit);
      final int maskHi = hiBit == 63 ? -1 : ((1 << (hiBit + 1)) - 1);
      for (int r = 1; r <= newRowMax; r++) {
        final int off = r * _words;
        if (wLo == wHi) {
          dst[off + wLo] &= maskLo & maskHi;
        } else {
          dst[off + wLo] &= maskLo;
          dst[off + wHi] &= maskHi;
        }
      }

      // -- trim to the rows that actually hold something ----------------------
      int newMin = 1;
      while (newMin <= newRowMax && _rowEmpty(dst, newMin, wLo, wHi)) {
        newMin++;
      }
      if (newMin > newRowMax) {
        // Every obstacle on screen was flyable and the playfield was fine — the
        // car simply could not be anywhere legal. This is the physics saying no.
        return _dead(world, nextFrame, FailureCause.unreachable, peak);
      }
      int newMax = newRowMax;
      while (newMax > newMin && _rowEmpty(dst, newMax, wLo, wHi)) {
        newMax--;
      }

      final int live = _countBits(dst, newMin, newMax, wLo, wHi);
      if (live > peak) peak = live;

      // Swap the buffers rather than copying: `dst` becomes the new `src`.
      final Uint64List tmp = src;
      src = dst;
      dst = tmp;
      rowMin = newMin;
      rowMax = newMax;
      validLo = wLo;
      validHi = wHi;
      origin = nextOrigin;
      frame = nextFrame;

      if (tape != null) {
        tape.add(_snapshot(src, validLo, validHi));
        origins!.add(origin);
        rowTops!.add(rowMax);
      }

      if (world.courseCleared) {
        return ProofResult(
          survivable: true,
          frames: frame,
          obstaclesCleared: world.obstaclesCleared,
          peakStates: peak,
          witness: tape == null
              ? null
              : _recoverWitness(tape, origins!, rowTops!, rowMin, rowMax),
        );
      }
    }

    return ProofResult(
      survivable: false,
      frames: frame,
      obstaclesCleared: world.obstaclesCleared,
      peakStates: peak,
      deathFrame: frame,
      deathObstacleIndex: world.obstaclesCleared,
      cause: FailureCause.frameBudget,
    );
  }

  ProofResult _dead(
    CourseWorld world,
    int frame,
    FailureCause cause,
    int peak,
  ) => ProofResult(
    survivable: false,
    frames: frame,
    obstaclesCleared: world.obstaclesCleared,
    peakStates: peak,
    deathFrame: frame,
    deathObstacleIndex: world.obstaclesCleared,
    cause: cause,
  );

  /// Walks the recorded frames backwards to turn "some path survived" into the
  /// actual taps that survive.
  ///
  /// The walk is almost forced. A state whose framesSinceFlap is n > 1 can only
  /// have come from (S - n, n - 1) one frame earlier without a flap — there is
  /// no other way to hold a counter of n. Only n == 1 leaves a choice, and any
  /// of the choices is a flap, so the tap for that frame is known even before
  /// the predecessor is picked.
  List<bool> _recoverWitness(
    List<Uint64List> tape,
    List<int> origins,
    List<int> rowTops,
    int rowMin,
    int rowMax,
  ) {
    final int last = tape.length - 1;

    // Any surviving state will do; take the first one found.
    int s = 0;
    int n = -1;
    for (int r = rowMin; r <= rowMax && n < 0; r++) {
      final int off = r * _words;
      for (int w = 0; w < _words && n < 0; w++) {
        final int word = tape[last][off + w];
        if (word == 0) continue;
        for (int b = 0; b < _wordBits; b++) {
          if ((word >>> b) & 1 == 1) {
            s = origins[last] + w * _wordBits + b;
            n = r;
            break;
          }
        }
      }
    }
    if (n < 0) throw StateError('witness asked for on a dead search');

    // inputs[t] is the tap taken at frame t, which produces frame t + 1.
    final List<bool> inputs = List<bool>.filled(last, false);
    for (int t = last; t >= 1; t--) {
      if (n > 1) {
        // Forced: no flap, and the predecessor's S is this one minus the counter.
        inputs[t - 1] = false;
        s -= n;
        n -= 1;
      } else {
        // A flap. Frame 0 is the exception: the run reaches it BY flapping out
        // of `ready`, so the tap at frame 0 is `true` either way.
        inputs[t - 1] = true;
        s -= 1;
        if (t - 1 == 0) {
          n = 0;
        } else {
          int found = -1;
          final int prevOrigin = origins[t - 1];
          final int bit = s - prevOrigin;
          if (bit >= 0 && bit < _words * _wordBits) {
            for (int r = 1; r <= rowTops[t - 1]; r++) {
              final int word = tape[t - 1][r * _words + (bit >> 6)];
              if ((word >>> (bit & (_wordBits - 1))) & 1 == 1) {
                found = r;
                break;
              }
            }
          }
          if (found < 0) {
            throw StateError('witness back-chain lost the trail at frame $t');
          }
          n = found;
        }
      }
    }
    return inputs;
  }

  /// A copy of [src] holding ONLY the words that were written this frame.
  ///
  /// The live buffers deliberately leave words outside the current band stale
  /// rather than paying to clear them, which is safe while `validLo`/`validHi`
  /// are consulted on every read. A snapshot outlives that bookkeeping, so it
  /// has to be scrubbed — otherwise the witness back-chain could latch onto a
  /// bit left over from two frames ago and "recover" a path that was never
  /// reachable.
  static Uint64List _snapshot(Uint64List src, int validLo, int validHi) {
    final Uint64List out = Uint64List(src.length);
    for (int off = 0; off < src.length; off += _words) {
      for (int w = validLo; w <= validHi; w++) {
        out[off + w] = src[off + w];
      }
    }
    return out;
  }

  static bool _rowEmpty(Uint64List bits, int row, int wLo, int wHi) {
    final int off = row * _words;
    for (int w = wLo; w <= wHi; w++) {
      if (bits[off + w] != 0) return false;
    }
    return true;
  }

  static int _countBits(
    Uint64List bits,
    int rowMin,
    int rowMax,
    int wLo,
    int wHi,
  ) {
    int total = 0;
    for (int r = rowMin; r <= rowMax; r++) {
      final int off = r * _words;
      for (int w = wLo; w <= wHi; w++) {
        int v = bits[off + w];
        while (v != 0) {
          v &= v - 1;
          total++;
        }
      }
    }
    return total;
  }

  /// `dst[wLo..wHi] |= src shifted left by [shift] bits`, where a negative
  /// [shift] means a shift toward lower indices (upward on screen).
  ///
  /// Reads outside `[srcLo, srcHi]` are treated as zero: those words of the
  /// source buffer were not written this frame and hold stale bits from two
  /// frames ago.
  static void _orShifted(
    Uint64List dst,
    int dOff,
    Uint64List src,
    int sOff,
    int shift,
    int wLo,
    int wHi,
    int srcLo,
    int srcHi,
  ) {
    // Dart's % is non-negative for a positive divisor, so this is a floor
    // decomposition and works unchanged for negative shifts.
    final int r = shift % _wordBits;
    final int q = (shift - r) ~/ _wordBits;
    if (r == 0) {
      for (int w = wLo; w <= wHi; w++) {
        final int a = w - q;
        if (a < srcLo || a > srcHi) continue;
        dst[dOff + w] |= src[sOff + a];
      }
      return;
    }
    final int inv = _wordBits - r;
    for (int w = wLo; w <= wHi; w++) {
      final int a = w - q;
      final int b = a - 1;
      int v = 0;
      if (a >= srcLo && a <= srcHi) v |= src[sOff + a] << r;
      if (b >= srcLo && b <= srcHi) v |= src[sOff + b] >>> inv;
      if (v != 0) dst[dOff + w] |= v;
    }
  }
}

// =============================================================================
// Margins
// =============================================================================

/// The tightest clearance the best possible path ever has to a pipe, in
/// playfield-heights.
///
/// HOW THIS IS COMPUTED, AND WHY IT IS THE BEST PATH RATHER THAN SOME PATH:
///
/// re-run the whole proof with the car fattened by `c` against every pipe. The
/// course is clearable at fatness `c` exactly when some path keeps at least `c`
/// of clearance the whole way, and clearability is monotone in `c` — fatter is
/// never easier. So the largest `c` that still proves survivable IS the
/// best-path bottleneck, and it can be found by bisection. No path enumeration,
/// no heuristic, and the answer is a property of the course rather than of any
/// particular player.
///
/// Clearance is measured to PIPES. The playfield edges kill too, but a course
/// whose best path hugs the ceiling is a different complaint and would hide
/// behind the same number.
///
/// Returns a negative number when the course is not survivable at all.
double tightestMargin(
  Course course, {
  FairnessProver? prover,
  double upper = 0.2,
  double tolerance = 5e-5,
}) {
  final FairnessProver p = prover ?? FairnessProver();
  if (!p.prove(course, inflate: 0.0).survivable) return -1.0;
  double lo = 0.0;
  double hi = upper;
  if (p.prove(course, inflate: hi).survivable) return hi;
  while (hi - lo > tolerance) {
    final double mid = (lo + hi) / 2;
    if (p.prove(course, inflate: mid).survivable) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return lo;
}

// =============================================================================
// Independent physics facts, used to check the prover from outside
// =============================================================================

/// How many consecutive frames one obstacle straddles the car horizontally.
///
/// This is the length of time the car is pinned inside a single gap, and it is
/// the number that makes a lone obstacle harder than its height suggests: the
/// car does not have to fit through the gap, it has to STAY inside it for this
/// many frames while gravity keeps working.
///
/// [scrollSpeed] is a parameter because the ramp moves it. The window is
/// `(carWidth + obstacleWidth) / scrollSpeed` seconds wide, so a faster world
/// pins the car for FEWER frames — which is the one way in which speeding the
/// game up makes a single obstacle easier rather than harder, and the reason the
/// gap can be narrowed further at the plateau than it could be at the start.
int obstacleOverlapFrames({
  double dt = defaultDt,
  double scrollSpeed = GameModel.scrollSpeed,
}) {
  final Course probe = Course(
    name: 'probe',
    gaps: const <CourseGap>[CourseGap(0.5, GameModel.gapHeight)],
    difficulty: FixedDifficulty(scrollSpeed: scrollSpeed),
  );
  final CourseWorld world = CourseWorld(probe, dt: dt);
  final double carLeft = GameModel.carX - GameModel.carWidth / 2;
  final double carRight = GameModel.carX + GameModel.carWidth / 2;
  int count = 0;
  for (int i = 0; i < 10000; i++) {
    world.step();
    bool over = false;
    for (final WorldObstacle o in world.obstacles) {
      if (o.index == 0 && carLeft < o.right && carRight > o.left) over = true;
    }
    if (over) count++;
    if (world.courseCleared) break;
  }
  return count;
}

/// The smallest vertical distance any [frames]-frame trajectory can be squeezed
/// into, together with the inputs that achieve it.
///
/// WHY THIS IS HERE: it is a check on the prover that shares no code with the
/// prover. There is no reachable set, no lattice and no bitmap — it simply
/// enumerates flap patterns, integrates them exactly as `GameModel.tick` does,
/// and measures the highest and lowest y each one visits. A single obstacle is
/// clearable exactly when its gap is at least `carHeight` plus this number, so
/// the prover's answer for a one-obstacle course can be predicted from outside
/// and then compared.
///
/// It searches patterns with at most [maxFlaps] flaps, so the answer is an UPPER
/// bound: if the true optimum needed more flaps this returns something slightly
/// too big. That is the safe direction for a check — it can accuse the prover of
/// being too strict, it cannot excuse a prover that is too generous — and a
/// caller that finds the two numbers drifting apart should widen [maxFlaps]
/// rather than relax the comparison.
ExcursionBound minimumExcursion(
  int frames, {
  int maxFlaps = 2,
  int maxStartCounter = 90,
  double dt = defaultDt,
}) {
  final double step = GameModel.gravity * dt;
  ExcursionBound best = const ExcursionBound(double.infinity, 0, <int>[]);

  double measure(int startCounter, List<int> flaps) {
    int n = startCounter;
    double y = 0.0;
    double lo = double.infinity;
    double hi = -double.infinity;
    int next = 0;
    for (int k = 1; k <= frames; k++) {
      if (next < flaps.length && flaps[next] == k) {
        n = 1;
        next++;
      } else {
        n++;
      }
      y += (GameModel.flapImpulse + n * step) * dt;
      if (y < lo) lo = y;
      if (y > hi) hi = y;
    }
    return hi - lo;
  }

  void consider(int startCounter, List<int> flaps) {
    final double e = measure(startCounter, flaps);
    if (e < best.excursion) {
      best = ExcursionBound(e, startCounter, List<int>.unmodifiable(flaps));
    }
  }

  void recurse(int startCounter, List<int> flaps, int from) {
    consider(startCounter, flaps);
    if (flaps.length >= maxFlaps) return;
    for (int k = from; k <= frames; k++) {
      flaps.add(k);
      recurse(startCounter, flaps, k + 1);
      flaps.removeLast();
    }
  }

  for (int n0 = 0; n0 <= maxStartCounter; n0++) {
    recurse(n0, <int>[], 1);
  }
  return best;
}

/// The result of [minimumExcursion]: how tight a corridor is flyable, and the
/// inputs that fly it.
class ExcursionBound {
  /// Highest y minus lowest y over the window, in playfield-heights.
  final double excursion;

  /// framesSinceFlap on entering the window.
  final int startCounter;

  /// Frames (1-based, within the window) the trajectory flaps on.
  final List<int> flapFrames;

  const ExcursionBound(this.excursion, this.startCounter, this.flapFrames);
}

// =============================================================================
// A second, deliberately naive implementation
// =============================================================================

/// The same search written the obvious way: a hash set of explicit
/// (y, framesSinceFlap) states, with y accumulated frame by frame in doubles
/// exactly as `GameModel.tick` accumulates it.
///
/// WHY A SECOND IMPLEMENTATION EXISTS: the fast prover is bit-twiddling on a
/// closed-form lattice, and a shifted word is not something a reader can check
/// by eye. This one is slow and obviously correct. `test/fairness_prover_test.dart`
/// runs both over the same courses and requires the same answers — so a bug in
/// the shifts shows up as a disagreement rather than as a confident wrong number.
///
/// It is capped by [maxStates] and returns null if it blows through the cap,
/// because "I ran out of memory" must never be reported as "unsurvivable".
class ReferenceProver {
  /// Seconds per frame.
  final double dt;

  /// Extra clearance demanded, matching [FairnessProver.epsilon].
  final double epsilon;

  const ReferenceProver({this.dt = defaultDt, this.epsilon = defaultEpsilon});

  /// Runs the naive search. Null means the cap was hit, not that the course
  /// failed.
  bool? survives(
    Course course, {
    double inflate = 0.0,
    int maxStates = 2000000,
    int maxFrames = 100000,
  }) {
    final CourseWorld world = CourseWorld(course, dt: dt);

    // Key packs (y quantised to 1e-9, framesSinceFlap). The quantisation only
    // ever merges states that are the SAME state reached two ways — genuinely
    // different lattice positions are 6.1e-4 apart, six orders of magnitude
    // coarser than the key's resolution.
    final Map<int, _RefState> live = <int, _RefState>{
      _key(GameModel.startY, 0): _RefState(GameModel.startY, GameModel.flapImpulse, 0),
    };

    int frame = 0;
    while (frame < maxFrames) {
      world.step();
      final AliveBand band = aliveBand(world.obstacles, inflate);
      final double lo = band.lo + epsilon;
      final double hi = band.hi - epsilon;

      final Map<int, _RefState> next = <int, _RefState>{};
      for (final _RefState st in live.values) {
        // Don't flap: gravity is added first, then the NEW velocity moves y.
        // Same order as `GameModel.tick`, on purpose.
        final double vFall = st.v + GameModel.gravity * dt;
        final double yFall = st.y + vFall * dt;
        if (yFall >= lo && yFall <= hi) {
          next.putIfAbsent(
            _key(yFall, st.n + 1),
            () => _RefState(yFall, vFall, st.n + 1),
          );
        }
        // Flap: velocity is assigned, not added.
        final double vFlap = GameModel.flapImpulse + GameModel.gravity * dt;
        final double yFlap = st.y + vFlap * dt;
        if (yFlap >= lo && yFlap <= hi) {
          next.putIfAbsent(_key(yFlap, 1), () => _RefState(yFlap, vFlap, 1));
        }
      }

      if (next.isEmpty) return false;
      if (next.length > maxStates) return null;
      live
        ..clear()
        ..addAll(next);
      frame++;
      if (world.courseCleared) return true;
    }
    return null;
  }

  static int _key(double y, int n) => (y * 1e9).round() * 1024 + n;
}

class _RefState {
  final double y;
  final double v;
  final int n;
  const _RefState(this.y, this.v, this.n);
}
