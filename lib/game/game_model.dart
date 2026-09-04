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

/// The three numbers that decide how hard the game is at one moment.
///
/// A value type rather than three loose doubles so that "the difficulty at
/// obstacle 300" is one thing a caller can hold, print and compare. The report
/// in `tool/prove_fairness.dart` and the ramp tests both want exactly that.
class DifficultySettings {
  /// Playfield-widths per second the world moves past the car.
  final double scrollSpeed;

  /// Height of the flyable gap, in playfield-heights.
  final double gapHeight;

  /// Playfield-widths between consecutive obstacles.
  final double obstacleSpacing;

  const DifficultySettings({
    required this.scrollSpeed,
    required this.gapHeight,
    required this.obstacleSpacing,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DifficultySettings &&
          other.scrollSpeed == scrollSpeed &&
          other.gapHeight == gapHeight &&
          other.obstacleSpacing == obstacleSpacing;

  @override
  int get hashCode => Object.hash(scrollSpeed, gapHeight, obstacleSpacing);

  @override
  String toString() =>
      'DifficultySettings(scrollSpeed: $scrollSpeed, gapHeight: $gapHeight, '
      'obstacleSpacing: $obstacleSpacing)';
}

/// The difficulty ramp: how hard the game is, as a pure function of how far the
/// player has got.
///
/// ============================================================================
/// WHY THE RAMP TAKES PROGRESS AS AN ARGUMENT AND NOT A CLOCK
/// ============================================================================
///
/// The obvious way to make a game speed up is to read the wall clock and scale
/// something by elapsed seconds. That would put a hidden input into
/// `lib/game/` — the same hidden input `tick(dt)` and [GapPattern] exist to keep
/// out — and it would take the replay system down with it: a recording is a
/// seed plus a list of tap frames, and re-executing it has to produce the same
/// run. If the difficulty depended on the time of day, the same taps would fly a
/// different course tomorrow, every recorded run would stop verifying, and the
/// ghost would race a game nobody played.
///
/// So progress enters the way time and variation already do: as an argument.
/// Every function here is `int -> double` with no state, no clock and no
/// randomness, which is what keeps a run a pure function of (seed, taps).
///
/// ============================================================================
/// WHY THE RAMP HAD TO BE PROVED AND NOT MERELY TUNED
/// ============================================================================
///
/// `tool/prove_fairness.dart` certifies that a perfect player can clear every
/// course the game generates. Narrowing the gap and speeding the world up eats
/// into the room that proof measures, and it does so DEEP IN A RUN — at obstacle
/// 300, where nobody playtests. A ramp tuned by feel could therefore be
/// unwinnable and look fine: the first minute would play better than ever and
/// the wall would be somewhere no reviewer ever reached. The plateau values
/// below are the ones the prover still certifies with room to spare; see the
/// ramp section of that tool's report for the margin they leave.
///
/// ============================================================================
/// WHAT "PROGRESS" MEANS, AND WHY IT IS TWO DIFFERENT INTEGERS
/// ============================================================================
///
/// Two of the three settings belong to an OBSTACLE and one belongs to a MOMENT,
/// so they are keyed differently and deliberately:
///
///   * [gapHeightAt] and [spacingAt] take an obstacle INDEX. An obstacle's shape
///     and where it stands are decided once, when it is built, and must not
///     change afterwards — a pipe that narrowed while the car was inside it
///     would be a rule the player cannot see.
///   * [scrollSpeedAt] takes the SCORE — obstacles already passed. How fast the
///     world moves is a property of the current moment, not of any one pipe.
///
/// Both are "progress", both are monotone, and both are integers the model
/// already carries, so neither adds state.
abstract final class Difficulty {
  /// Obstacles of unramped warm-up before anything gets harder.
  ///
  /// PLAYABLE BECAUSE: the opening of a Flappy game is where a new player learns
  /// the tap rhythm, and learning it against a moving target is how a game feels
  /// unfair rather than hard. Ten obstacles is about thirteen seconds — long
  /// enough to find the rhythm, short enough that a returning player is not made
  /// to sit through a tutorial.
  ///
  /// It also keeps the shipped tuning honest: for the first ten obstacles the
  /// game is EXACTLY the game that was there before the ramp, which is what
  /// `test/tuning_constants_test.dart` measures.
  static const int warmUpObstacles = 10;

  /// Obstacles the ramp takes to go from the shipped tuning to its hardest.
  ///
  /// PLAYABLE BECAUSE: 40 obstacles is around a minute of play, so the change is
  /// under a tenth of a percent per obstacle — below the threshold at which a
  /// player notices any single step, which is what makes a ramp feel like
  /// getting better at the game rather than like being cheated.
  static const int rampObstacles = 40;

  /// The obstacle at which the ramp reaches its hardest setting and stops.
  ///
  /// THE RAMP IS BOUNDED, AND THAT IS THE WHOLE DESIGN. An unbounded ramp — one
  /// that keeps tightening for as long as the run lasts — is unwinnable at some
  /// depth by construction, and the only question is where. Being unwinnable
  /// eventually is not a difficulty curve, it is a hidden time limit. A ramp
  /// that plateaus has ONE hardest setting, which is a thing a prover can be
  /// pointed at and a thing a player can eventually master.
  static const int plateauObstacle = warmUpObstacles + rampObstacles;

  /// Scroll speed at the plateau, in playfield-widths per second. 6.7% up on
  /// [GameModel.scrollSpeed].
  ///
  /// A pipe crosses from the right edge to the car in 1.46s instead of 1.56, and
  /// obstacles arrive every 1.25s instead of every 1.33 — less warning, and the
  /// main thing the player feels. It also SHORTENS the window an obstacle spends
  /// level with the car, from 43 frames to 40, which is the one way speeding up
  /// makes a single gap easier; see `obstacleOverlapFrames` in
  /// `tool/fairness.dart`.
  ///
  /// WHY ONLY 6.7%, WHEN A GAME THAT SPEEDS UP BY HALF WOULD BE MORE DRAMATIC:
  /// because the prover would not certify it. See [tightestGapHeight] for the
  /// measurements — speed is the more expensive of the two levers, and the
  /// shipped game does not have as much room to spend as it looks like it does.
  static const double topScrollSpeed = 0.4800;

  /// Gap height at the plateau, in playfield-heights. A tenth narrower than
  /// [GameModel.gapHeight] — 8.13 car-heights instead of 9.03.
  ///
  /// The gap narrows around an UNCHANGED centre band. [GameModel.clampGapCentre]
  /// still uses the base [GameModel.gapHeight], so `minGapCentre` and
  /// `maxGapCentre` stay 0.22 and 0.78 all the way to the plateau. That is
  /// deliberate: re-deriving the band from the ramped height would let gap
  /// centres drift closer to the ceiling and the floor, which is a SECOND
  /// difficulty change — longer transitions — hiding inside the first. One knob,
  /// one effect.
  ///
  /// ==========================================================================
  /// HOW THIS NUMBER AND [topScrollSpeed] WERE CHOSEN, WHICH IS THE POINT
  /// ==========================================================================
  ///
  /// Not by feel. `tool/ramp_probe.dart` holds the whole game at a candidate
  /// plateau and sweeps 10,000 three-obstacle windows of the shipped pattern,
  /// reporting the tightest clearance the best possible path ever has. The
  /// shipped game starts with 0.0602 of that — 1.94 car-heights — and a ramp
  /// spends it. Measured, on the same sweep:
  ///
  ///     speed   gap     worst margin        verdict
  ///     0.45    0.28    0.0602  1.94 ch     the game before the ramp
  ///     0.45    0.23    0.0388  1.25 ch     gap alone: costs exactly half the
  ///                                         height it removes
  ///     0.54    0.28    0.0351  1.13 ch     speed alone, +20%
  ///     0.48    0.252   0.0411  1.33 ch     SHIPPED
  ///     0.5175  0.26    0.0308  0.99 ch     under one car-height: rejected
  ///     0.5625  0.22    ——                  2 windows UNSURVIVABLE
  ///     0.54    0.23  (spacing 0.54)        66 windows unsurvivable; a
  ///                                         continuous run dies at obstacle 372
  ///     0.60    0.21    ——                  105 windows unsurvivable; a
  ///                                         continuous run dies at obstacle 372
  ///
  /// The last three are the finding. A ramp that reaches 0.60 / 0.21 — which is
  /// a perfectly ordinary-looking "the game gets a third faster and the gaps get
  /// a quarter tighter" — produces courses NO player can clear, and it produces
  /// the first of them around obstacle 372: six minutes into a run, where
  /// nobody would ever have found it by playing. The plateau above is where the
  /// ramp was bounded so that could not happen.
  static const double tightestGapHeight = 0.2520;

  /// Spacing at the plateau, in playfield-widths.
  ///
  /// EQUAL TO THE BASE SPACING, AND THAT IS A FINDING RATHER THAN AN OVERSIGHT.
  /// Tightening the spacing as well was tried and the prover refused it — see
  /// the table on [tightestGapHeight], where dropping it to 0.54 alongside a
  /// raised speed makes 66 of 4,000 windows unsurvivable. The mechanism is
  /// legible: the free air between two obstacles is what a worst-case climb from
  /// a low gap to a high one has to be paid out of, raising the speed already
  /// shortens it, and pulling the pipes closer together subtracts from exactly
  /// the same budget twice.
  ///
  /// The constant is kept as a named plateau value rather than deleted so the
  /// ramp has one shape, and so the next person to reach for this lever finds
  /// the reason it was not pulled.
  ///
  /// WRITTEN OUT AS A LITERAL RATHER THAN AS `GameModel.obstacleSpacing`, which
  /// is what it means: an alias would be the SAME compile-time constant, so
  /// swapping one for the other produces two byte-identical programs and
  /// `tool/mutate.dart` would report a survivor nothing could ever kill. The
  /// duplication is instead pinned by an equality assertion in
  /// `test/difficulty_test.dart`, which a real change to either number fails.
  static const double tightestSpacing = 0.60;

  /// How far along the ramp [progress] is: 0.0 during the warm-up, 1.0 at and
  /// after [plateauObstacle], and linear in between.
  ///
  /// Clamped at BOTH ends, and the upper clamp is the load-bearing one — it is
  /// what makes the game's hardest setting a value rather than a limit
  /// approached forever. A negative progress cannot happen in a run but is
  /// pinned to 0.0 anyway, because a function that returns a negative fraction
  /// for a nonsense input hands the caller a gap TALLER than the base one and
  /// says nothing about it.
  static double rampFraction(int progress) {
    if (progress <= warmUpObstacles) return 0.0;
    if (progress >= plateauObstacle) return 1.0;
    return (progress - warmUpObstacles) / rampObstacles;
  }

  /// Blends [from] into [to] by [t].
  ///
  /// Written as `from * (1 - t) + to * t` rather than the shorter
  /// `from + (to - from) * t` because only this form is EXACT at the endpoints:
  /// at t = 1 it evaluates to `to` bit for bit, and at t = 0 to `from` bit for
  /// bit. The short form goes through a subtraction and an addition that can each
  /// round, so the plateau would land a few ulps away from the constant it is
  /// supposed to be — and then `gapHeightAt(plateauObstacle)` would not equal
  /// [tightestGapHeight], and neither the fairness report nor a test could state
  /// the hardest setting as a number.
  static double blend(double from, double to, double t) =>
      from * (1.0 - t) + to * t;

  /// How fast the world moves once [obstaclesPassed] obstacles are behind the
  /// car.
  static double scrollSpeedAt(int obstaclesPassed) =>
      blend(GameModel.scrollSpeed, topScrollSpeed, rampFraction(obstaclesPassed));

  /// The gap height obstacle [obstacleIndex] is built with.
  static double gapHeightAt(int obstacleIndex) => blend(
    GameModel.gapHeight,
    tightestGapHeight,
    rampFraction(obstacleIndex),
  );

  /// The distance placed between obstacle [obstacleIndex] and the one before it.
  static double spacingAt(int obstacleIndex) => blend(
    GameModel.obstacleSpacing,
    tightestSpacing,
    rampFraction(obstacleIndex),
  );

  /// All three settings at one point on the ramp, for reports and tests.
  ///
  /// Only meaningful where the two kinds of progress coincide — which they do
  /// everywhere the ramp is being DESCRIBED rather than applied. Nothing in the
  /// model calls this; `tick` reads the three functions with their own
  /// arguments.
  static DifficultySettings settingsAt(int progress) => DifficultySettings(
    scrollSpeed: scrollSpeedAt(progress),
    gapHeight: gapHeightAt(progress),
    obstacleSpacing: spacingAt(progress),
  );
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

  /// Aspect (height / width) of the screen the collision boxes are defined
  /// for. Normalised x and y are scaled by screen width and height
  /// independently, so a box's real shape depends on this. Stating it here
  /// makes the dependency reviewable instead of accidental.
  ///
  /// THE TRAP THIS CONSTANT CLOSES, spelled out once because it is the least
  /// obvious thing in this file and it has already cost one bug:
  ///
  /// Normalised coordinates make the game screen-independent in POSITION and
  /// screen-DEPENDENT in SHAPE. A renderer turns a normalised box into pixels
  /// by multiplying x by the screen width and y by the screen height — two
  /// different numbers — so "0.10 wide by 0.05 tall" is 108 x 120 px on a
  /// 1080 x 2400 phone, taller than it is wide, and 108 x 54 px on a square
  /// 1080 x 1080 one, twice as wide as it is tall. Same two numbers, two
  /// different shapes. Nothing in this file can notice, because collision is
  /// tested in normalised coordinates where a box is exactly what the numbers
  /// say it is.
  ///
  /// That is harmless while the car is an abstract rectangle. It stops being
  /// harmless the moment a sprite with proportions of its own has to sit inside
  /// that rectangle: for a 286 x 120 image to fill its hitbox, the hitbox has
  /// to come out 2.383 : 1 ON SCREEN — and what shape it comes out is a fact
  /// about the screen, not about the numbers. So the screen has to be named,
  /// and this is where it is named.
  ///
  /// THE CONTRACT FOR A RENDERER RUNNING AT A DIFFERENT ASPECT: either
  /// letterbox the playfield to [referenceAspect] and draw inside that, or
  /// accept that the car's drawn shape drifts from the sprite's. Nothing here
  /// implements letterboxing and this file does not care which is chosen — it
  /// only insists the choice is made knowingly rather than discovered later.
  /// `lib/main.dart` currently takes the second option: it fills the window, so
  /// on a screen far from 20:9 the car is drawn slightly stretched or squashed.
  /// The GAME is identical either way, because the rules never see a pixel.
  static const double referenceAspect = 2400 / 1080;

  /// Width / height of the Miata sprite's own pixels (286 x 120).
  ///
  /// The asset is cropped to its opaque bounds, so this is the car's shape and
  /// not the shape of a canvas with transparent margins around it. Re-export
  /// the artwork at different proportions and this number has to change with
  /// it; `test/car_geometry_test.dart` pins the hitbox to it so that cannot be
  /// forgotten silently.
  static const double carSpriteAspect = 286 / 120;

  /// Height of the car's collision box, in playfield-heights.
  ///
  /// PLAYABLE BECAUSE: [gapHeight] divided by this is 9.0, so a gap is nine
  /// car-heights tall. Flappy Bird's is about 4.2 — but its bird is nearly
  /// square and this car is two and a third times wider than it is tall, so the
  /// quantity that actually sets difficulty here is the AREA the box sweeps,
  /// not its height in isolation. That area is what was held fixed; see
  /// [carWidth].
  static const double carHeight = 0.031;

  /// Width of the car's collision box, in playfield-widths. DERIVED, never
  /// typed in — that derivation is the entire point of the two constants above.
  ///
  /// Multiplying by [referenceAspect] converts a height in playfield-heights
  /// into the width that draws the same number of pixels; multiplying by
  /// [carSpriteAspect] then stretches that square into the car's real
  /// proportions. The result, 0.1642, is a box of 177.3 x 74.4 px at the
  /// reference aspect — the same 2.383 : 1 as the sprite, so the drawn car
  /// fills it edge to edge instead of overhanging it.
  ///
  /// WHY DIFFICULTY DID NOT JUMP WHEN THIS CHANGED: the previous pair (0.10 by
  /// 0.05, both hand-picked) covered 12960 px^2 at the reference aspect; this
  /// pair covers 13193, which is 1.8% more. The box is now much wider and much
  /// shorter — a genuine change in WHICH near misses are survivable — but it
  /// occupies the same fraction of the screen, so a run is neither noticeably
  /// easier nor harder. `test/car_geometry_test.dart` pins that within 5%.
  ///
  /// The danger window, the time the car spends level with a pipe, is
  /// (carWidth + obstacleWidth) / scrollSpeed = 0.72s, up from 0.58s. Longer
  /// because the box really is wider now, and paid for by a gap that is nine
  /// car-heights tall instead of five and a half.
  static const double carWidth = carHeight * referenceAspect * carSpriteAspect;

  /// Width of one obstacle, in playfield-widths.
  ///
  /// PLAYABLE BECAUSE: 0.16 against a 0.60 spacing leaves 0.44 of clear air
  /// between pipes, so at any instant the player is looking at a wall or at a
  /// runway, never at an ambiguous smear of both. Flappy Bird's pipes are
  /// 52/288 = 0.18 wide.
  static const double obstacleWidth = 0.16;

  /// How fast the world moves past the car at the START of a run, in
  /// playfield-widths per second.
  ///
  /// PLAYABLE BECAUSE: an obstacle takes (1.0 - carX) / 0.45 = 1.55s to travel
  /// from the right edge to the car. That is long enough to see it, aim, and
  /// commit. Flappy Bird scrolls at 144 px/s over a 288 px playfield, which is
  /// 0.50 in these units — this is a shade gentler.
  ///
  /// NO LONGER THE SPEED FOR THE WHOLE RUN. [Difficulty] ramps it upward with
  /// the score; this is the value it starts from and the value it holds for the
  /// whole warm-up. Read `Difficulty.scrollSpeedAt(score)` for what a given
  /// frame actually uses.
  static const double scrollSpeed = 0.45;

  /// Distance between consecutive obstacles at the start of a run, in
  /// playfield-widths.
  ///
  /// PLAYABLE BECAUSE: 0.60 / [scrollSpeed] is one obstacle every 1.33s, so the
  /// player gets a beat between decisions instead of a continuous corridor.
  /// Flappy Bird spaces its pipes 172/288 = 0.60 apart. Same number, arrived at
  /// honestly.
  ///
  /// The ramp reads it through `Difficulty.spacingAt(index)`, which currently
  /// holds it constant for the whole run — see [Difficulty.tightestSpacing] for
  /// why that lever was left alone.
  static const double obstacleSpacing = 0.60;

  /// Height of the flyable gap at the start of a run, in playfield-heights.
  ///
  /// PLAYABLE BECAUSE: 0.28 is 9.0 car-heights (see [carHeight]) and it is also
  /// wider than one full flap arc — a flap climbs 0.118 — so a player can flap
  /// *inside* a gap without immediately clipping its ceiling. That last
  /// property is what makes the gap threadable rather than a coin flip.
  ///
  /// [Difficulty] narrows it with the obstacle index down to
  /// [Difficulty.tightestGapHeight]. An obstacle is built with
  /// `Difficulty.gapHeightAt(index)` and carries that height for life.
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
  ///
  /// DERIVED FROM THE BASE [gapHeight] AND NOT FROM THE RAMPED ONE, on purpose.
  /// See [Difficulty.tightestGapHeight]: holding the band still means the ramp
  /// narrows gaps without also spreading them further apart vertically, so one
  /// knob has one effect. A ramped gap is strictly inside the band the base gap
  /// occupied, so it also stays further from the ceiling and the floor than the
  /// base one ever did.
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

  /// Builds obstacle [index] at [x], asking [gapCentreFor] where its gap goes
  /// and [Difficulty] how tall it is.
  ///
  /// The height is baked in HERE, once, and then carried on the obstacle for the
  /// rest of its life. Looking it up again later — while the car is level with
  /// the pipe, say — would let the ramp narrow a gap the player is already
  /// inside, which is a rule nothing on screen could express.
  Obstacle _spawnAt(double x, int index) => Obstacle(
    index: index,
    x: x,
    width: obstacleWidth,
    gapCentre: clampGapCentre(gapCentreFor(index)),
    gapHeight: Difficulty.gapHeightAt(index),
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
    //
    // THE SPEED IS READ FROM `score`, i.e. from LAST frame's points, because
    // this frame's have not been awarded yet — scoring happens further down.
    // Which of the two it is barely matters to a player and matters completely
    // to the fairness prover, whose `CourseWorld` has to reproduce this timeline
    // frame for frame; so it is written down here rather than left to whichever
    // line happened to come first.
    final double travel = Difficulty.scrollSpeedAt(score) * dt;
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
    } else {
      // Read ONCE and used for both the test and the placement. Two calls would
      // be two chances to sample the ramp at different arguments, and a pipe
      // placed a spacing it was not tested against is a pipe the prover's world
      // puts somewhere else.
      final double spacing = Difficulty.spacingAt(nextIndex);
      if (next.last.x <= playfieldRight - spacing) {
        // Placed exactly one spacing to the right of the newest obstacle, rather
        // than at the right edge. Both spawn in almost the same place, but
        // measuring from the previous obstacle means the frame-to-frame rounding
        // never accumulates: obstacle 50 is exactly 50 spacings behind obstacle 0
        // however jittery the frame rate was in between.
        next.add(_spawnAt(next.last.x + spacing, nextIndex));
        nextIndex++;
      }
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
