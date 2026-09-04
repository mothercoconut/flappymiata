/// A bot that plays properly, built out of the assist solver.
///
/// ============================================================================
/// WHY THE OLD BOTS STOPPED BEING USEFUL
/// ============================================================================
///
/// The stock policies in `tool/headless_sim.dart` are heuristics: tap on a
/// cadence, hold an altitude, aim at the next gap centre. They were written
/// against a game with one fixed speed and one fixed gap height, and the
/// difficulty ramp moved both out from under them. Measured on the shipped
/// course, `holdAltitude` now scores ZERO — it dies on the first obstacle —
/// and `chaseGap` reaches twelve.
///
/// That is a problem for the automated checks rather than for the bots. "Does
/// the game still work" is answered by driving it and seeing how far a run
/// gets, and an instrument that scores nothing cannot tell a working game from
/// a broken one: every regression and every improvement reads as zero. The
/// checks were getting weaker exactly as the game got harder.
///
/// ============================================================================
/// WHAT THIS ONE DOES INSTEAD
/// ============================================================================
///
/// It does not guess. `lib/ui/assist.dart` computes, for a bounded horizon, the
/// exact SET of states from which some continuation survives — the same
/// reachability argument `tool/fairness.dart` makes about a whole course, run
/// backwards over the next obstacle or two. The bot's whole policy is then two
/// lines:
///
///   * while coasting keeps it inside that set, coast;
///   * on the frame coasting would leave it, tap.
///
/// Within one horizon that cannot die. Leaving the set is the definition of
/// having no future, and the bot only ever moves to a state that is still in it.
/// What is NOT guaranteed is the join between horizons: a pass looks a bounded
/// distance ahead, so the bot can be steered into a corner that only shows up
/// after the horizon it was planning against. That is the same limitation the
/// assist display has and it is stated in the same place.
///
/// ============================================================================
/// WHY "TAP AS LATE AS POSSIBLE" AND NOT SOMETHING CLEVERER
/// ============================================================================
///
/// Any choice inside the surviving set is safe for the horizon, so the tie-break
/// is free. Tapping at the last possible frame is the one worth having: it is
/// the smallest number of taps, it keeps the car low and therefore keeps the
/// whole flap arc available above it, and — the part that matters for a test
/// instrument — it is DETERMINISTIC and needs no tuning constant of its own.
///
/// It has one visible consequence, and it is worth knowing before reading a
/// score off this bot: flying as late as possible means flying CLOSE, so this
/// bot collects risk points at a high rate. It is not the safest possible
/// driver, it is the one that survives while giving away the least room.
///
/// Pure Dart, no Flutter, no `dart:io`: runs under `dart run` and under
/// `flutter test` unchanged, exactly like the driver it plugs into.
library;

import 'package:flappymiata/game/game_model.dart';
import 'package:flappymiata/ui/assist.dart';

import 'headless_sim.dart';

/// A [Policy] that plays the game using the assist solver's own answers.
///
/// STATEFUL, which every other policy in the driver is not: it holds the
/// current backward pass so that one search covers about sixty frames instead
/// of being redone on each of them. The state is a cache and nothing else —
/// the decision on any frame is a function of the model handed in, and two bots
/// given the same run make the same choices.
///
/// [solver] is injectable so a caller can read `passes` off it afterwards and
/// report what the bot cost, rather than estimating it.
Policy solverPolicy({AssistSolver? solver}) {
  final AssistSolver search = solver ?? AssistSolver();
  AssistPlan? plan;

  return (GameModel model, int frame) {
    // The first tap: a `ready` model does not move at all, so nothing can be
    // planned about it until the run has begun.
    if (model.state == RunState.ready) return true;
    if (model.state == RunState.dead) return false;

    if (plan == null || !plan!.isCurrent || !plan!.covers(frame)) {
      plan = search.plan(model, frame);
    }
    final AssistAdvice? advice = plan?.adviseAt(model, frame);

    // No pass could be built — no obstacle ahead, or a state the search cannot
    // represent. Coasting is the honest answer: it is what the driver would do
    // with no policy at all, and inventing a tap here would be exactly the kind
    // of guess this bot exists to avoid.
    if (advice == null) return false;

    // Doing nothing still leaves a future, so do nothing. This is the branch
    // that runs on almost every frame.
    if (advice.latestSafeCoast >= 1) return false;

    // Coasting one more frame leaves the surviving set, so this is the frame to
    // tap on — if tapping is still one of the moves that survives. When it is
    // not, the car is already lost inside this horizon and the tap changes
    // nothing; it is still made, because a doomed car flying is better viewing
    // than a doomed car falling, and nothing downstream reads it either way.
    return advice.flapNow || advice.doomed;
  };
}
