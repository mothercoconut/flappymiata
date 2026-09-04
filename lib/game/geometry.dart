/// Shapes and the playfield they live in — plain Dart, no renderer.
///
/// This file is the other half of `lib/game/game_model.dart`: the model owns
/// the *rules*, this owns the *shapes* the rules are stated in. It is split out
/// because collision is the one part of the game a reader has to be able to
/// check by hand, and it is much easier to check when the box maths sits on its
/// own rather than three screens down inside a physics step.
///
/// Same directory rule as everything else under `lib/game/`: no Flame, no
/// Flutter, no clock, no randomness. See `lib/game/README.md`.
library;

// -----------------------------------------------------------------------------
// The playfield.
//
// EVERY number in this directory is normalised — a fraction of the playfield,
// never a pixel. x runs 0.0 (left edge) to 1.0 (right edge), y runs 0.0 (top)
// to 1.0 (bottom). The model therefore never learns how big the screen is, and
// a phone and a tablet play an identical game.
//
// y grows DOWNWARD. That is the convention every 2D renderer uses, and matching
// it here means the renderer never has to flip anything.
// -----------------------------------------------------------------------------

/// Top edge of the playfield.
const double playfieldTop = 0.0;

/// Bottom edge of the playfield.
const double playfieldBottom = 1.0;

/// Left edge of the playfield.
const double playfieldLeft = 0.0;

/// Right edge of the playfield, and the x an obstacle is born at.
const double playfieldRight = 1.0;

/// An axis-aligned rectangle in normalised playfield coordinates.
///
/// "Axis-aligned" means the edges are parallel to x and y — no rotation. That
/// restriction is the whole reason collision in this game is four comparisons
/// instead of a separating-axis test: a rotated car would need real geometry,
/// and a car that only ever moves straight up and down does not.
class Box {
  /// Smaller x. Left edge.
  final double left;

  /// Smaller y. Top edge, because y grows downward.
  final double top;

  /// Larger x. Right edge.
  final double right;

  /// Larger y. Bottom edge.
  final double bottom;

  const Box({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  /// True when this box and [other] share any area.
  ///
  /// THE WHOLE OF AABB COLLISION, AND WHY IT IS ENOUGH HERE:
  ///
  /// Two axis-aligned boxes overlap when they overlap on BOTH axes at once.
  /// Miss on either axis and there is a gap you could slide a sheet of paper
  /// through, so they cannot be touching. Four comparisons, no square roots, no
  /// trigonometry, and — the part that matters for a game — no case where it is
  /// nearly right.
  ///
  /// It is enough for this game because nothing in it rotates. The car is a
  /// horizontal rectangle that only moves up and down; a pipe is a vertical
  /// rectangle that only moves left. Boxes that are already axis-aligned lose
  /// nothing by being tested as boxes.
  ///
  /// STRICT `<` AND `>`, NOT `<=` AND `>=`: two boxes that share exactly one
  /// edge do NOT count as a hit. A car whose roof is at precisely the same y as
  /// the pipe lip has scraped through, and the player who threaded that
  /// deserves the point. Touching-is-death is also the version that feels
  /// unfair, because the pixel on screen is a rounded-off version of the number
  /// tested here.
  bool overlaps(Box other) =>
      left < other.right &&
      right > other.left &&
      top < other.bottom &&
      bottom > other.top;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Box &&
          other.left == left &&
          other.top == top &&
          other.right == right &&
          other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'Box(l: $left, t: $top, r: $right, b: $bottom)';
}

/// One obstacle: a pair of pipes with a gap between them, drifting leftward.
///
/// Immutable for the same reason the model is — every field on a frame is a
/// value, so "the obstacle moved" means "here is the next obstacle", and no
/// code anywhere can edit a frame the renderer is already holding.
///
/// WHY EACH OBSTACLE CARRIES ITS OWN [scored] FLAG, rather than the model
/// keeping a side list of scored ids or simply comparing x against the car:
///
/// 1. Scoring is a one-shot event, but `tick` runs 60 times a second. "Is this
///    obstacle behind the car?" is TRUE for about half a second — roughly 33
///    consecutive frames — so a model that scored on that question alone would
///    award 33 points per pipe. The flag is what turns a lasting condition into
///    a single edge.
/// 2. Putting the flag on the obstacle means the fact travels with the thing it
///    is about, and is thrown away when that obstacle is dropped off the left
///    edge. A side list of scored ids would have to be pruned by hand, and the
///    day someone forgets, it grows for as long as the run lasts.
class Obstacle {
  /// Which obstacle this is, counted from 0 at the start of the run.
  ///
  /// Kept on the obstacle, and strictly increasing, because it is the input to
  /// the gap-position function. Reuse an index and the run would repeat itself;
  /// skip one and it would not match a recorded run.
  final int index;

  /// Centre x, in playfield-widths from the left edge. Decreases every tick.
  final double x;

  /// Full width of the pipe, in playfield-widths.
  final double width;

  /// Centre of the gap, in normalised y.
  final double gapCentre;

  /// Height of the gap, in normalised y. The car has to fit through this.
  final double gapHeight;

  /// Whether this obstacle has already added its point. See the class comment:
  /// this is what stops one pipe scoring on every frame it spends behind the
  /// car.
  final bool scored;

  /// The closest this obstacle's pipes have ever come to the car, in
  /// playfield-heights. [double.infinity] until the car has been level with it
  /// at all.
  ///
  /// WHY IT LIVES ON THE OBSTACLE AND NOT ON THE MODEL, which is the same
  /// argument [scored] makes and for the same reason: the measurement is a fact
  /// ABOUT THIS PIPE. Keeping it here means it travels with the thing it
  /// describes, it is thrown away when the obstacle leaves the screen, and the
  /// model never has to hold a side-map of index-to-clearance that somebody has
  /// to remember to prune.
  ///
  /// WHY INFINITY RATHER THAN NULL OR ZERO. Zero would be a lie — zero is the
  /// clearance of a pass that shaved the lip, which is the most impressive
  /// thing in the game, and an unmeasured obstacle must never be confused with
  /// that one. Null would make every arithmetic use of this field a null check.
  /// Infinity is the identity of `min`, so "no measurement yet" and "the
  /// smallest measurement so far" are the same expression, and it is `isFinite`
  /// that separates them.
  final double minClearance;

  const Obstacle({
    required this.index,
    required this.x,
    required this.width,
    required this.gapCentre,
    required this.gapHeight,
    this.scored = false,
    this.minClearance = double.infinity,
  });

  /// Left edge, in playfield-widths.
  double get left => x - width / 2;

  /// Right edge, in playfield-widths.
  double get right => x + width / 2;

  /// The bottom lip of the upper pipe — the top of the flyable gap.
  double get gapTop => gapCentre - gapHeight / 2;

  /// The top lip of the lower pipe — the bottom of the flyable gap.
  double get gapBottom => gapCentre + gapHeight / 2;

  /// The upper pipe: from the ceiling down to the top of the gap.
  Box get topBox =>
      Box(left: left, top: playfieldTop, right: right, bottom: gapTop);

  /// The lower pipe: from the bottom of the gap down to the floor.
  Box get bottomBox =>
      Box(left: left, top: gapBottom, right: right, bottom: playfieldBottom);

  /// The clearance a PERFECTLY CENTRED pass through this gap would have, for a
  /// car [carHeight] tall — i.e. all the room this obstacle has to give.
  ///
  /// Half, because the spare height is shared between the pipe above and the
  /// pipe below: a car sitting dead centre is this far from each of them.
  /// Negative when the gap is shorter than the car, which is a gap nothing can
  /// pass; the shipped game cannot build one, and callers that might be handed
  /// one say what they do about it.
  double roomFor(double carHeight) => (gapHeight - carHeight) / 2;

  /// True when a car spanning [carLeft] to [carRight] is LEVEL with this
  /// obstacle — the x half of [Box.overlaps], and therefore exactly the frames
  /// on which this pipe could collide with that car.
  ///
  /// Strict on both sides, matching [Box.overlaps]: a car whose nose is exactly
  /// on the pipe's left edge has not reached it yet.
  ///
  /// WHY THIS IS A METHOD RATHER THAN TWO COMPARISONS AT THE ONE PLACE THAT
  /// NEEDS IT. `GameModel.tick` needs it to decide which frames a clearance is
  /// measured over, and written inline there the boundary is UNTESTABLE: pipe
  /// positions come out of the physics, so no test can arrange for an obstacle
  /// edge to land on exactly the car's edge, and `<` and `<=` would differ only
  /// on that unreachable input. As a function of two doubles the boundary is one
  /// line of a test — which is the same reason `Box.overlaps` is its own method
  /// rather than four comparisons inside the collision check.
  bool isLevelWith(double carLeft, double carRight) =>
      carLeft < right && carRight > left;

  /// The smallest distance between [car] and either of this obstacle's two
  /// pipes, in playfield-heights.
  ///
  /// Zero means the car's roof or its sills sat exactly on a pipe lip — the
  /// closest a pass can be without being a crash, because [Box.overlaps] is
  /// strict. Negative means the boxes are genuinely overlapping, which
  /// `GameModel.tick` reads as a collision on the same frame.
  ///
  /// ONLY MEANINGFUL WHILE THE CAR AND THE OBSTACLE OVERLAP HORIZONTALLY. Once
  /// a pipe is beside the car, the gap between the two boxes is purely
  /// vertical, so a single number says everything. Ahead of that the nearest
  /// point of the pipe is diagonally away and this number means nothing;
  /// `GameModel.tick` is what restricts the measurement to the frames where it
  /// does mean something.
  ///
  /// WHY IT IS WRITTEN AS "ROOM MINUS HOW FAR OFF CENTRE" RATHER THAN AS THE
  /// MINIMUM OF TWO DISTANCES, which is what the sentence above describes:
  ///
  ///     to the upper pipe   a = car.top    - gapTop
  ///     to the lower pipe   b = gapBottom  - car.bottom
  ///
  ///     a + b = gapHeight - carHeight = 2 * roomFor(carHeight)
  ///     a - b = 2 * (gapCentre - carCentre)
  ///
  /// so min(a, b) = (a + b)/2 - |a - b|/2 = roomFor(carHeight) - |carCentre -
  /// gapCentre|, exactly, with no comparison in it. That matters twice over: it
  /// is the same number by algebra rather than by a branch a reader has to
  /// check, and it says out loud what the quantity MEANS — the room this gap
  /// had, less however much of it the driver gave away by not being centred.
  double clearanceTo(Box car) =>
      roomFor(car.bottom - car.top) -
      ((car.top + car.bottom) / 2 - gapCentre).abs();

  /// This obstacle shifted by [dx] playfield-widths. Negative moves it left,
  /// toward the car.
  Obstacle movedBy(double dx) => Obstacle(
    index: index,
    x: x + dx,
    width: width,
    gapCentre: gapCentre,
    gapHeight: gapHeight,
    scored: scored,
    minClearance: minClearance,
  );

  /// This obstacle, marked as having paid out its point. One-way: nothing
  /// un-scores an obstacle, which is precisely the property that makes double
  /// counting impossible.
  Obstacle markScored() => Obstacle(
    index: index,
    x: x,
    width: width,
    gapCentre: gapCentre,
    gapHeight: gapHeight,
    scored: true,
    minClearance: minClearance,
  );

  /// This obstacle, remembering that the car came within [clearance] of it.
  ///
  /// Keeps the SMALLER of the two, so calling it on every frame the car spends
  /// level with this pipe leaves the closest approach behind. Monotone
  /// downward, in the same way [markScored] is one-way: a run cannot improve
  /// its record against a pipe by flying wide of it afterwards, and a pipe
  /// cannot be talked out of a scrape that already happened.
  ///
  /// RETURNS THE RECEIVER WHEN NOTHING IMPROVED, and that is a property rather
  /// than an optimisation detail — `test/risk_score_test.dart` asserts the
  /// identity, in "a repeat of the current minimum is not a change". Two
  /// reasons it is worth having:
  ///
  ///   1. A pipe is level with the car for about 43 frames and only a few of
  ///      those are new minima, so the common case allocates nothing.
  ///   2. It pins the boundary. `>=` and `>` differ on exactly one input — a
  ///      repeat of the current minimum — and both produce an EQUAL obstacle,
  ///      so a value comparison could never tell them apart. Identity can, and
  ///      that is what stops this line being a comparison no test can reach.
  Obstacle withClearance(double clearance) {
    if (clearance >= minClearance) return this;
    return Obstacle(
      index: index,
      x: x,
      width: width,
      gapCentre: gapCentre,
      gapHeight: gapHeight,
      scored: scored,
      minClearance: clearance,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Obstacle &&
          other.index == index &&
          other.x == x &&
          other.width == width &&
          other.gapCentre == gapCentre &&
          other.gapHeight == gapHeight &&
          other.scored == scored &&
          other.minClearance == minClearance;

  @override
  int get hashCode =>
      Object.hash(index, x, width, gapCentre, gapHeight, scored, minClearance);

  @override
  String toString() =>
      'Obstacle(#$index, x: $x, gapCentre: $gapCentre, '
      'gapHeight: $gapHeight, scored: $scored, '
      'minClearance: $minClearance)';
}
