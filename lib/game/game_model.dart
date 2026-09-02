/// The game's rules, as a plain-Dart value type.
///
/// WHY THERE IS NO FLAME OR FLUTTER IMPORT IN THIS FILE:
/// everything here can be exercised by `flutter test` in milliseconds with no
/// window, no canvas and no frame pump. The moment this file imports a
/// renderer, testing the rules means booting a renderer, and the rules stop
/// being cheap to check. `lib/game/README.md` states this as a directory rule.
library;

import 'geometry.dart';

// Re-exported so that one import — `package:flappymiata/game/game_model.dart` —
// brings the whole model with it. `Obstacle` is part of the model's surface:
// anything that reads a `GameModel` also has to be able to read the obstacles
// hanging off it.
export 'geometry.dart';

/// Where the gap in obstacle number [index] should sit, as a normalised y.
///
/// WHY THE MODEL TAKES THIS AS A PARAMETER INSTEAD OF GENERATING IT:
///
/// A Flappy game needs the gaps to be somewhere different every time, and the
/// obvious way to get that is a random number generator. This file cannot have
/// one. Randomness is a hidden input — it makes `tick` return different answers
/// for identical arguments, and a function like that cannot be tested by
/// comparing it to an expected value, only by loosely asserting ranges.
///
/// So variation enters the way TIME already enters: as an argument. `tick`
/// takes `dt` rather than reading a clock; the model takes a gap function
/// rather than rolling dice. The caller supplies the variation, and the model
/// stays a pure function of its inputs. That is what makes both the determinism
/// test and every collision test below possible — a test can hand in
/// `(index) => 0.5` and know exactly where the pipes will be.
typedef GapPattern = double Function(int index);

/// The three states a run can be in. Exactly three — there is no "paused" and
/// no "starting"; anything else is a rendering concern.
enum RunState {
  /// Before the first tap. The car hangs still and waits.
  ready,

  /// The run is live. Gravity applies, taps lift the car.
  playing,

  /// The run is over. Nothing moves until [GameModel.reset].
  dead,
}

/// An immutable snapshot of the run at one instant.
///
/// WHY IMMUTABLE, when a mutable object with `y += ...` would be shorter:
///
/// 1. A frame becomes a value, not an event. `tick` is a pure function from
///    (model, dt) to model, so a test can assert on the returned model without
///    caring what order anything else ran in.
/// 2. Nothing can change the model behind the renderer's back. The renderer
///    holds a snapshot, and that snapshot stays true until it is replaced.
/// 3. Replaying a run is just re-running the same calls. That is what makes
///    the determinism test possible at all.
///
/// COORDINATES: [y] is *normalised* — 0.0 is the top of the playfield, 1.0 is
/// the bottom. This class does not know how tall the screen is, and must not
/// learn: turning 0.37 into a pixel row is the renderer's job. Two devices with
/// different screens therefore play an identical game.
///
/// The horizontal axis works the same way and runs 0.0 (left) to 1.0 (right),
/// measured in *playfield-widths*. The car never moves along it: it sits at
/// [carX] and the obstacles come to it. That is the classic Flappy arrangement,
/// and it is a real simplification rather than a trick of presentation — with
/// the car pinned, the only moving quantity is the obstacle list, and "has the
/// player travelled far enough to score" becomes "has this pipe gone past".
///
/// TIME: enters only through the `dt` parameter of [tick]. There is no clock in
/// this file — no `DateTime.now()`, no `Stopwatch`, no `Random`. That is what
/// makes the model deterministic: the same calls always produce the same
/// numbers, on any machine, at any frame rate, in a test where no real time
/// passes at all.
class GameModel {
  // -------------------------------------------------------------------------
  // Tuning constants. Named, so they can be found and changed in one place — a
  // literal buried inside `velocity + 2.2 * dt` is invisible to anyone asking
  // "why does this feel wrong?".
  // -------------------------------------------------------------------------

  /// Downward acceleration, in playfield-heights per second squared.
  ///
  /// WHAT "PLAYABLE" MEANT WHEN THIS VALUE WAS CHOSEN: at 60fps a car dropped
  /// from rest crosses the whole playfield in about 0.95s — that is
  /// sqrt(2 * 1.0 / 2.2). Much slower and the car floats and the game feels
  /// weightless; much faster and a single missed tap is unrecoverable. Classic
  /// Flappy Bird runs at roughly 1100 px/s^2 over a ~512 px playfield, which is
  /// about 2.15 in these units, so this sits deliberately in that neighbourhood.
  static const double gravity = 2.2;

  /// The velocity a flap *assigns*, in playfield-heights per second. Negative
  /// because y grows downward.
  ///
  /// Paired with [gravity] this gives an arc that rises about 12% of the
  /// playfield — flapImpulse^2 / (2 * gravity) — and peaks after about 0.33s.
  /// High enough that one tap visibly clears something, small enough that the
  /// player has to keep tapping.
  static const double flapImpulse = -0.72;

  /// Where a fresh run starts: slightly above centre, so there is more room to
  /// fall than to rise. The first mistake most players make is tapping too
  /// much, not too little.
  static const double startY = 0.4;

  /// Top edge of the playfield, in normalised coordinates.
  static const double minY = playfieldTop;

  /// Bottom edge of the playfield, in normalised coordinates.
  static const double maxY = playfieldBottom;

  // -------------------------------------------------------------------------
  // Obstacle tuning. Every one of these is in playfield fractions, and every
  // one was picked against the same yardstick: the classic Flappy Bird numbers,
  // converted out of pixels into fractions of its 288x512 playfield, then
  // nudged to suit a car that is wider than a bird.
  // -------------------------------------------------------------------------

  /// The car's fixed x, in playfield-widths from the left edge.
  ///
  /// PLAYABLE BECAUSE: left of centre. Everything the player has to react to
  /// arrives from the right, so 70% of the screen is warning and 30% is
  /// history. Pushing the car to the middle halves the reaction time for no
  /// gain. This is also the value the dev harness already drew the car at, so
  /// the picture does not move when the rules arrive.
  static const double carX = 0.30;

  /// Width of the car's collision box, in playfield-widths.
  ///
  /// PLAYABLE BECAUSE: a tenth of the screen. Together with [obstacleWidth] it
  /// sets how long the car spends level with a pipe — the danger window is
  /// (carWidth + obstacleWidth) / scrollSpeed, about 0.58s here, which is close
  /// to the original's 0.6s. Wider than the drawn car would feel unfair; the
  /// box is meant to be the generous reading of where the car is.
  static const double carWidth = 0.10;

  /// Height of the car's collision box, in playfield-heights.
  ///
  /// PLAYABLE BECAUSE: [gapHeight] divided by this is 5.6, so a gap is between
  /// five and six car-heights tall. Flappy Bird's is about 4.2. Slightly
  /// roomier on purpose: this game is a course deliverable that has to be
  /// demonstrable on camera, not a test of the presenter's reflexes.
  static const double carHeight = 0.05;

  /// Width of one obstacle, in playfield-widths.
  ///
  /// PLAYABLE BECAUSE: 0.16 against a 0.60 spacing leaves 0.44 of clear air
  /// between pipes, so at any instant the player is looking at a wall or at a
  /// runway, never at an ambiguous smear of both. Flappy Bird's pipes are
  /// 52/288 = 0.18 wide.
  static const double obstacleWidth = 0.16;

  /// How fast the world moves past the car, in playfield-widths per second.
  ///
  /// PLAYABLE BECAUSE: an obstacle takes (1.0 - carX) / 0.45 = 1.55s to travel
  /// from the right edge to the car. That is long enough to see it, aim, and
  /// commit. Flappy Bird scrolls at 144 px/s over a 288 px playfield, which is
  /// 0.50 in these units — this is a shade gentler.
  static const double scrollSpeed = 0.45;

  /// Distance between consecutive obstacles, in playfield-widths.
  ///
  /// PLAYABLE BECAUSE: 0.60 / [scrollSpeed] is one obstacle every 1.33s, so the
  /// player gets a beat between decisions instead of a continuous corridor.
  /// Flappy Bird spaces its pipes 172/288 = 0.60 apart. Same number, arrived at
  /// honestly.
  static const double obstacleSpacing = 0.60;

  /// Height of the flyable gap, in playfield-heights.
  ///
  /// PLAYABLE BECAUSE: 0.28 is 5.6 car-heights (see [carHeight]) and it is also
  /// wider than one full flap arc — a flap climbs 0.118 — so a player can flap
  /// *inside* a gap without immediately clipping its ceiling. That last
  /// property is what makes the gap threadable rather than a coin flip.
  static const double gapHeight = 0.28;

  /// The least clear space allowed between a gap and the ceiling or floor, in
  /// playfield-heights.
  ///
  /// PLAYABLE BECAUSE: a gap flush against an edge is not a hard obstacle, it
  /// is an unfair one — the car has to sit half outside the playfield, where
  /// the out-of-bounds rule kills it anyway. 0.08 is one and a half car-heights
  /// of breathing room, which is enough to be flown through deliberately.
  static const double gapMargin = 0.08;

  /// The highest a gap centre may sit. Derived, never typed in twice.
  static const double minGapCentre = gapHeight / 2 + gapMargin;

  /// The lowest a gap centre may sit. Derived, never typed in twice.
  static const double maxGapCentre = playfieldBottom - gapHeight / 2 - gapMargin;

  /// Which of the three states this snapshot is in.
  final RunState state;

  /// Vertical position: 0.0 is the top of the playfield, 1.0 the bottom.
  final double y;

  /// Vertical speed in playfield-heights per second. Negative is upward.
  final double velocity;

  /// Every obstacle currently on the playfield, left-most first.
  ///
  /// Unmodifiable, not merely `final`: `final` would stop the field being
  /// reassigned and do nothing at all about `model.obstacles.clear()`. A
  /// renderer holding last frame's snapshot has to be unable to edit it, or the
  /// immutability the rest of this class depends on is only a convention.
  final List<Obstacle> obstacles;

  /// How many obstacles the car has cleared this run.
  final int score;

  /// The index the next obstacle to be created will carry.
  ///
  /// Held on the model rather than derived from `obstacles.last.index + 1`
  /// because obstacles get dropped once they leave the screen, and a run that
  /// briefly had none on screen would otherwise restart its indices at 0 and
  /// replay the gap sequence from the beginning.
  final int nextObstacleIndex;

  /// Where each obstacle's gap goes. See [GapPattern] for why this is injected.
  ///
  /// Deliberately NOT part of `==` or [hashCode]: it is configuration, not
  /// state. Two snapshots with the same car, the same pipes and the same score
  /// describe the same instant of play whether or not the closures that
  /// produced them are the same object — and Dart closures compare by identity,
  /// so including it would make two runs built from identical-looking lambdas
  /// compare unequal for a reason that has nothing to do with the game.
  final GapPattern gapCentreFor;

  /// The initial state of every run: [RunState.ready], parked at [startY], not
  /// moving, with an empty playfield and no score.
  ///
  /// [gapCentreFor] defaults to [defaultGapCentre], so `const GameModel.ready()`
  /// still works and still gives a varied run. Pass something else — a test
  /// passing `(index) => 0.5` — to put the gaps exactly where you want them.
  const GameModel.ready({this.gapCentreFor = defaultGapCentre})
    : state = RunState.ready,
      y = startY,
      velocity = 0.0,
      obstacles = const <Obstacle>[],
      score = 0,
      nextObstacleIndex = 0;

  /// Private, because the only legal ways to reach a new state are [tick],
  /// [flap] and [reset]. Nothing outside this file can hand itself a running
  /// game that skipped the rules.
  const GameModel._({
    required this.state,
    required this.y,
    required this.velocity,
    required this.obstacles,
    required this.score,
    required this.nextObstacleIndex,
    required this.gapCentreFor,
  });

  /// The default gap pattern: a scatter over the obstacle index that looks
  /// random and is not.
  ///
  /// WHY A HASH AND NOT A RANDOM NUMBER GENERATOR: a generator carries state,
  /// and state means the answer for obstacle 7 depends on how many numbers were
  /// drawn before it. This depends on nothing but 7. It can be evaluated out of
  /// order, in a test, twice, on two machines, and give the same answer — which
  /// is exactly what `lib/game/`'s no-clock-no-randomness rule is protecting.
  ///
  /// The mix itself is MurmurHash3's 32-bit finaliser, with the index first
  /// multiplied by a large odd constant so that consecutive indices do not
  /// produce visibly related outputs. Every step is masked back to 32 bits;
  /// Dart's ints are 64-bit here, and letting the intermediate values grow past
  /// 32 bits would change the answer.
  static double defaultGapCentre(int index) {
    // `index + 1` so that obstacle 0 is not hashing zero, which several mixes
    // map to zero and would peg the first gap to the very top of its range.
    int h = (index + 1) & 0xFFFFFFFF;
    h = (h * 0x9E3779B1) & 0xFFFFFFFF;
    h = h ^ (h >> 16);
    h = (h * 0x85EBCA6B) & 0xFFFFFFFF;
    h = h ^ (h >> 13);
    h = (h * 0xC2B2AE35) & 0xFFFFFFFF;
    h = h ^ (h >> 16);

    // 2^32, so `unit` lands in [0.0, 1.0).
    final double unit = h / 4294967296.0;
    return minGapCentre + unit * (maxGapCentre - minGapCentre);
  }

  /// Pulls [centre] back inside the range a gap is allowed to occupy.
  ///
  /// This is applied to whatever [gapCentreFor] returns, not just to
  /// [defaultGapCentre]. An injected pattern is caller-supplied data, and the
  /// model is the thing that knows a gap at y = 0.02 is unflyable; trusting the
  /// caller to have clamped is how an unwinnable obstacle reaches a player.
  static double clampGapCentre(double centre) {
    if (centre < minGapCentre) return minGapCentre;
    if (centre > maxGapCentre) return maxGapCentre;
    return centre;
  }

  /// The car's collision box if its centre were at [carY].
  ///
  /// Takes the y rather than reading the field so the same code can ask about a
  /// position the car has not moved to yet — which is what [tick] does, testing
  /// the *next* y before deciding whether the car survives to occupy it.
  static Box carBoxAt(double carY) => Box(
    left: carX - carWidth / 2,
    top: carY - carHeight / 2,
    right: carX + carWidth / 2,
    bottom: carY + carHeight / 2,
  );

  /// The car's collision box right now.
  Box get carBox => carBoxAt(y);

  /// True when a car centred at [carY] overlaps either pipe of any obstacle.
  ///
  /// Each obstacle is two boxes, not one: the pipe hanging from the ceiling and
  /// the pipe standing on the floor. The gap between them is not a third box —
  /// it is simply the space neither pipe occupies, which is why flying through
  /// it needs no special case at all. Touching nothing is the default.
  static bool _hitsAnyObstacle(double carY, List<Obstacle> obstacles) {
    final Box car = carBoxAt(carY);
    for (final Obstacle obstacle in obstacles) {
      if (car.overlaps(obstacle.topBox) || car.overlaps(obstacle.bottomBox)) {
        return true;
      }
    }
    return false;
  }

  /// Builds obstacle [index] at [x], asking [gapCentreFor] where its gap goes.
  Obstacle _spawnAt(double x, int index) => Obstacle(
    index: index,
    x: x,
    width: obstacleWidth,
    gapCentre: clampGapCentre(gapCentreFor(index)),
    gapHeight: gapHeight,
  );

  /// Advances the run by [dt] seconds and returns the *next* model. The
  /// receiver is untouched, so callers must use the return value.
  GameModel tick(double dt) {
    // `ready` and `dead` are both frozen: nothing moves in either. Returning
    // `this` instead of a copy is safe precisely because the object is
    // immutable — there is no way for the caller to change it afterwards.
    if (state != RunState.playing) return this;

    // INTEGRATION ORDER MATTERS, AND THIS IS THE ORDER THAT IS STABLE.
    //
    // Velocity is updated first, and the *new* velocity is what moves the
    // position. That is semi-implicit (symplectic) Euler. The naive order —
    // move by the old velocity, then update velocity — is explicit Euler, and
    // it quietly adds energy on every step: the same arc drawn that way climbs
    // a little higher each time and eventually flies apart. Semi-implicit Euler
    // does not, so one flap feels identical on frame 1 and on frame 10,000.
    // The two versions differ by one line and by one full frame of lag.
    final double nextVelocity = velocity + gravity * dt;
    final double nextY = y + nextVelocity * dt;

    // -- the world scrolls ---------------------------------------------------
    //
    // The car's x never changes; the obstacles come to it. Everything moves by
    // the same distance this frame, so the list stays sorted left-to-right and
    // `last` is always the right-most, newest obstacle.
    final double travel = scrollSpeed * dt;
    final List<Obstacle> next = <Obstacle>[];
    for (final Obstacle obstacle in obstacles) {
      final Obstacle moved = obstacle.movedBy(-travel);

      // Dropped once its right edge is past the left wall, i.e. once no part of
      // it is on screen. Not "once its centre is off", which would delete
      // pipes the player can still see. The car sits at x = 0.30, so an
      // obstacle is scored long before it reaches this line and no point can be
      // lost to it.
      if (moved.right >= playfieldLeft) next.add(moved);
    }

    // -- and a new obstacle arrives on cadence -------------------------------
    int nextIndex = nextObstacleIndex;
    if (next.isEmpty) {
      // Only reachable on the first tick of a run, when the playfield starts
      // bare. The obstacle is born at the right edge, giving the player the
      // full 1.55s of approach.
      next.add(_spawnAt(playfieldRight, nextIndex));
      nextIndex++;
    } else if (next.last.x <= playfieldRight - obstacleSpacing) {
      // Placed exactly [obstacleSpacing] to the right of the newest obstacle,
      // rather than at the right edge. Both spawn in almost the same place, but
      // measuring from the previous obstacle means the frame-to-frame rounding
      // never accumulates: obstacle 50 is exactly 50 spacings behind obstacle 0
      // however jittery the frame rate was in between.
      next.add(_spawnAt(next.last.x + obstacleSpacing, nextIndex));
      nextIndex++;
    }

    // -- scoring -------------------------------------------------------------
    //
    // An obstacle scores when its right edge is fully past the car's left edge,
    // not when the car passes its centre. That is a deliberate choice: with no
    // horizontal overlap remaining, the obstacle can never collide with the car
    // again, so "scored" also means "survived". A point in this game is always
    // a point for something the player actually got through.
    //
    // Scoring runs BEFORE the death checks below, so a point earned on the same
    // frame as a fatal crash still counts. The pipe that killed the car cannot
    // be the pipe that just scored — see the paragraph above.
    int nextScore = score;
    final double carLeft = carX - carWidth / 2;
    for (int i = 0; i < next.length; i++) {
      final Obstacle obstacle = next[i];
      // The `!scored` half is the whole guard. Without it this condition stays
      // true for every frame the obstacle spends behind the car — about 33 of
      // them — and one pipe pays out 33 points.
      if (!obstacle.scored && obstacle.right < carLeft) {
        next[i] = obstacle.markScored();
        nextScore++;
      }
    }

    final List<Obstacle> frozen = List<Obstacle>.unmodifiable(next);

    // -- death, route one: out of bounds -------------------------------------
    //
    // This check lives inside `tick` because `tick` is the only place y can
    // change, so it is the only place the bound can be newly crossed. A
    // separate `checkBounds()` would be a second thing every caller has to
    // remember, and the first caller to forget it gets a car that falls
    // silently through the floor.
    if (nextY < minY || nextY > maxY) {
      // y is pinned to whichever edge was crossed rather than left at its
      // overshoot, so a renderer drawing the wreck draws it against the ceiling
      // or the floor rather than somewhere off-screen. Note the death itself is
      // decided from the un-pinned `nextY` above, so pinning cannot hide a
      // crossing — it only tidies where the car comes to rest.
      final double restingY = nextY < minY ? minY : maxY;
      return GameModel._(
        state: RunState.dead,
        y: restingY,
        velocity: nextVelocity,
        obstacles: frozen,
        score: nextScore,
        nextObstacleIndex: nextIndex,
        gapCentreFor: gapCentreFor,
      );
    }

    // -- death, route two: hit a pipe ----------------------------------------
    //
    // Tested against the position the car is about to occupy, and against the
    // obstacles after they have moved, so both halves of the collision are
    // being asked about the same instant. Testing the old y against the new
    // pipes would let a fast car tunnel one frame's worth of the way into one.
    if (_hitsAnyObstacle(nextY, frozen)) {
      // No pinning here. Unlike the bounds case there is no edge to rest
      // against, and leaving y where the crash happened is also what lets a
      // test tell the two deaths apart: a car killed by a pipe is strictly
      // inside the playfield, a car killed by the bounds is exactly on it.
      return GameModel._(
        state: RunState.dead,
        y: nextY,
        velocity: nextVelocity,
        obstacles: frozen,
        score: nextScore,
        nextObstacleIndex: nextIndex,
        gapCentreFor: gapCentreFor,
      );
    }

    return GameModel._(
      state: RunState.playing,
      y: nextY,
      velocity: nextVelocity,
      obstacles: frozen,
      score: nextScore,
      nextObstacleIndex: nextIndex,
      gapCentreFor: gapCentreFor,
    );
  }

  /// Handles a tap and returns the next model.
  GameModel flap() {
    switch (state) {
      // The first tap does two jobs at once: it starts the run AND lifts the
      // car. Splitting those would mean the very first tap of every game did
      // nothing visible, which players read as a dropped input.
      case RunState.ready:
        return GameModel._(
          state: RunState.playing,
          y: y,
          velocity: flapImpulse,
          obstacles: obstacles,
          score: score,
          nextObstacleIndex: nextObstacleIndex,
          gapCentreFor: gapCentreFor,
        );

      // ASSIGNMENT, NOT ADDITION: `velocity = flapImpulse`, never
      // `velocity += flapImpulse`. This one line is what makes the controls
      // feel like Flappy Bird rather than like a rocket:
      //   - Every tap produces the identical arc no matter how fast the car was
      //     already falling, so a rescue tap at the last moment always works
      //     exactly as well as an early one.
      //   - Mashing cannot stack impulses into an escape velocity. The climb
      //     rate is capped at flapImpulse however fast the player taps.
      // With `+=`, the game is beaten by tapping quickly and nothing else.
      case RunState.playing:
        return GameModel._(
          state: RunState.playing,
          y: y,
          velocity: flapImpulse,
          obstacles: obstacles,
          score: score,
          nextObstacleIndex: nextObstacleIndex,
          gapCentreFor: gapCentreFor,
        );

      // Taps after death do nothing, and return a model equal to this one. The
      // player has to be able to see the final frame; a stray tap that
      // restarted the run instantly would hide it. [reset] is the deliberate
      // way back.
      case RunState.dead:
        return this;
    }
  }

  /// Returns a fresh [RunState.ready] model from any state. Deliberately
  /// ignores everything about the current model — position, velocity, the
  /// obstacles on screen and the score — because a restart that carried any of
  /// those over would be a restart in name only.
  ///
  /// The ONE thing it keeps is [gapCentreFor], which is not part of the run: it
  /// is the caller's choice of how this game generates its gaps, and silently
  /// swapping a test's fixed pattern back to the hash on restart would make
  /// every post-reset assertion a guess.
  GameModel reset() => GameModel.ready(gapCentreFor: gapCentreFor);

  /// Element-by-element list comparison. Written out because Dart's `List ==`
  /// is identity, so two separate lists holding equal obstacles are not equal
  /// to each other, and the determinism test compares exactly that.
  static bool _sameObstacles(List<Obstacle> a, List<Obstacle> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // Value equality, so tests can compare whole models instead of field by
  // field. It is what lets "a flap while dead changes nothing" and "the same
  // inputs produce the same run" each be a single assertion.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GameModel &&
          other.state == state &&
          other.y == y &&
          other.velocity == velocity &&
          other.score == score &&
          other.nextObstacleIndex == nextObstacleIndex &&
          _sameObstacles(other.obstacles, obstacles);

  @override
  int get hashCode => Object.hash(
    state,
    y,
    velocity,
    score,
    nextObstacleIndex,
    Object.hashAll(obstacles),
  );

  @override
  String toString() =>
      'GameModel(${state.name}, y: $y, velocity: $velocity, '
      'score: $score, obstacles: ${obstacles.length})';
}
