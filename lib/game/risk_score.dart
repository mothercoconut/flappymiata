/// The risk reward: how much a pass is worth ON TOP of the point for passing.
///
/// ============================================================================
/// THE PROBLEM THIS SOLVES
/// ============================================================================
///
/// Before this file, a pass down the middle of a gap and a pass that shaved the
/// lip were worth exactly one point each. The game therefore had nothing to say
/// about the only decision a Flappy player actually makes — how much room to
/// leave — and the safest possible run was also the highest-scoring one. That
/// is the wrong incentive for a game whose whole tension is "how close do you
/// dare".
///
/// ============================================================================
/// WHAT IS MEASURED, AND WHY IT IS A FRACTION RATHER THAN A DISTANCE
/// ============================================================================
///
/// `Obstacle.clearanceTo` gives a distance in playfield-heights, and
/// `Obstacle.roomFor` gives the largest distance that obstacle HAD to give — the
/// clearance of a perfectly centred pass. The reward is computed from the ratio,
///
///     r = 1 - clearance / room        ("how much of the available room was
///                                       given away")
///
/// so r = 0 is dead centre and r = 1 is touching a lip. Using the ratio rather
/// than the raw distance is load-bearing, because the difficulty ramp NARROWS
/// the gaps as a run goes on: `Difficulty.tightestGapHeight` is a tenth shorter
/// than the base gap, so `room` falls from 0.1245 to 0.1105 over the ramp. A
/// reward keyed on the raw distance would quietly pay more and more for the
/// same quality of driving, purely because the game had got harder — the player
/// would be paid for the ramp rather than for the risk. The ratio holds still.
///
/// ============================================================================
/// THE CURVE, AND WHICH NUMBERS IN IT ARE DERIVED AND WHICH ARE CHOSEN
/// ============================================================================
///
///     bonus = floor(maxRiskBonus * r^3)
///
/// TWO NUMBERS ARE CHOSEN, and there is no way to derive either of them —
/// they say how much the game wants to pay for risk, which is a design opinion
/// and not a measurement. They are written down here so the opinion is at least
/// visible:
///
///   * [maxRiskBonus] = 5. A perfectly threaded obstacle is worth six points
///     rather than one. Chosen so that a reckless style CAN roughly sextuple a
///     score and cannot do better than that — which keeps "how far did you get"
///     the dominant term and makes "how close did you fly" the tie-breaker,
///     rather than the other way round.
///
///   * the exponent, 3. Chosen for where it puts the first point, which is the
///     part a player feels. Everything else about the shape follows from it.
///
/// EVERYTHING BELOW IS DERIVED from those two, and is the reason the exponent
/// is 3 rather than 1 or 2. `floor(5 * r^3)` first reaches each value at
///
///     bonus  1        2        3        4        5
///     r    ≥ 0.5848   0.7368   0.8434   0.9283   1.0000
///
/// so a pass has to give away 58% of the room before it is paid anything at
/// all, and the last point costs the final 7%. With a LINEAR curve the same
/// table starts at r = 0.2 — a pass leaving four fifths of the room would be
/// paid, which is most passes, and the bonus would degenerate into a flat score
/// multiplier that says nothing about risk. With a SQUARE curve it starts at
/// r = 0.447. Cubic is where "paid nothing at all for an ordinary pass" starts
/// being true, and that is the property the whole feature is for.
///
/// WHERE THE FIRST THRESHOLD SITS RELATIVE TO THE PHYSICS, which is the one
/// number here that is measured rather than opinionated. An obstacle straddles
/// the car for 43 frames (`obstacleOverlapFrames` in `tool/fairness.dart`), and
/// over 43 frames the tightest corridor any trajectory can hold is 0.0869 tall
/// (`minimumExcursion`, which enumerates flap patterns and integrates them
/// longhand, sharing no code with anything here). So the very best possible pass
/// is still 0.0434 off centre, which is r = 0.349 — comfortably below the 0.5848
/// the first point costs.
///
/// That is the property worth stating out loud: **flying as well as the physics
/// allows earns nothing.** The reward is not for skill, it is for room given up,
/// and a player has to be deliberately closer than they need to be before the
/// game pays for it. `test/risk_score_test.dart` asserts it from the measured
/// excursion rather than from this paragraph.
///
/// MEASURED AT THE OTHER END TOO: `tool/solver_bot.dart` flies as late as it
/// safely can, and over a sixty-second run it collects 170 risk points against
/// 45 obstacles — an average of 3.8 of the 5 on offer. So the curve does
/// discriminate across its whole range, and the top of it is reachable by
/// deliberately flying at the lip rather than being decorative.
///
/// ============================================================================
/// WHY IT CANNOT BE FARMED
/// ============================================================================
///
/// The curve is only half the answer; the other half is WHEN it is paid, which
/// is `GameModel.tick`'s business and is stated there. Together:
///
///   1. **It is paid once, on the frame an obstacle scores.** The one-shot is
///      the existing `Obstacle.scored` flag, so a bonus cannot be collected
///      twice from one pipe any more than a point can.
///   2. **Scraping a pipe you never get past pays nothing.** An obstacle that
///      kills the car never scores, so the clearance recorded against it is
///      never cashed. Flying at a pipe is only worth something if you survive
///      it AND get past it.
///   3. **Loitering in a wide gap pays nothing.** The world scrolls whatever
///      the car does, so there is no hovering; and a pass that stays anywhere
///      near the middle is below the r = 0.5848 threshold and scores zero.
///   4. **It is bounded per obstacle.** [maxRiskBonus] is a ceiling, so no
///      single pipe can be worth an unbounded amount however it is flown.
///
/// Same directory rule as the rest of `lib/game/`: no Flame, no Flutter, no
/// clock, no randomness. Every function here is a pure function of two doubles,
/// which is what keeps a run — INCLUDING its risk score — a pure function of
/// (seed, taps) and therefore exactly replayable.
library;

/// The most a single obstacle can pay on top of its point. A CHOICE; see the
/// header.
const int maxRiskBonus = 5;

/// What one pass is worth on top of its point.
///
/// [clearance] is the closest the car came to either pipe, from
/// `Obstacle.clearanceTo`; [room] is the clearance a centred pass would have
/// had, from `Obstacle.roomFor`. Both in playfield-heights.
///
/// Total on every input, including the ones the shipped game cannot produce,
/// because a scoring rule that throws is a scoring rule that can end a run:
///
///   * `room` not positive — a gap no taller than the car, which nothing can
///     pass, so nothing about passing it can be graded: 0. This is also what
///     keeps a NEGATIVE room from turning the ratio upside down and paying out
///     for a gap the car could not have fitted through. Written as
///     `!(room > 0)` rather than `room <= 0` so a NaN takes the same exit,
///     matching `FixedStepAccumulator.stepsFor` in `replay.dart`.
///   * `clearance` not finite — the car was never level with this obstacle, so
///     nothing was measured. NOT the same as a clearance of zero, which is the
///     best pass in the game: 0.
///
/// Everything else falls out of the counting loop, which is why there is no
/// clamp anywhere below:
///
///   * a clearance at or beyond dead centre makes `given` zero or negative, so
///     no threshold is met and the answer is 0;
///   * a negative clearance — the boxes were overlapping, a crash rather than a
///     pass — makes `given` exceed 1, and the loop simply runs out of
///     thresholds at [maxRiskBonus].
///
/// WHY THRESHOLD-COUNTING RATHER THAN `floor(maxRiskBonus * given^3)`, which is
/// the same number: the two spellings are equal on every input, but the floor
/// version needs a clamp at each end to stay inside `0..maxRiskBonus`, and a
/// SATURATING clamp is continuous at its own boundary — `if (given > 1.0)
/// given = 1.0;` does exactly the same thing as `>=` would, so no test could
/// ever separate the two and `tool/mutate.dart` would report a survivor nothing
/// can kill. Counting thresholds puts the saturation in the loop BOUND instead,
/// where moving it by one changes the answer and a test can see it.
int riskBonus({required double clearance, required double room}) {
  if (!(room > 0)) return 0;
  if (!clearance.isFinite) return 0;

  // How much of the room on offer was given away. 0.0 is dead centre, 1.0 is
  // touching a lip; outside that range only for the degenerate inputs above.
  final double given = 1.0 - clearance / room;

  // Cubed, not `pow`: `dart:math` is banned in this directory, and three
  // multiplications is exactly what the exponent in the header means.
  final double earned = given * given * given * maxRiskBonus;

  // One point per threshold reached. Saturates at [maxRiskBonus] because that
  // is how many thresholds there are, and floors at 0 because a negative
  // `earned` reaches none of them.
  int bonus = 0;
  for (int step = 1; step <= maxRiskBonus; step++) {
    if (earned >= step) bonus++;
  }
  return bonus;
}
