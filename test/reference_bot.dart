/// A bot that can actually play, plus the loop that records it.
///
/// NOT a `_test.dart` file, so `flutter test` does not try to run it as a
/// suite. It exists because three test files and one tool all need "a real,
/// long, scoring run to work on", and three copies of that loop would be three
/// chances for one of them to record something subtly different.
///
/// The bot is a HEURISTIC and nothing here draws a conclusion from how well it
/// plays — see the long comment at the top of `tool/fairness.dart` for why a
/// policy can never answer a question about what is possible. Its only job is
/// to produce runs that look like play instead of like a crash test.
library;

import 'package:flappymiata/game/game_model.dart';
import 'package:flappymiata/game/replay.dart';

/// Records a run driven by [policy], which is asked once per frame, before that
/// frame's physics, exactly as a real tap would arrive.
Replay recordRun(
  int seed,
  bool Function(GameModel model, int frame) policy, {
  int maxFrames = 3000,
}) {
  final ReplayRecorder recorder = ReplayRecorder(seed: seed);
  while (!recorder.finished && recorder.frame < maxFrames) {
    if (policy(recorder.model, recorder.frame)) recorder.tap();
    if (!recorder.step()) break;
  }
  return recorder.replay;
}

/// Taps whenever the car is [lead] above the centre of the gap it is heading
/// for, or below it.
///
/// The lead is an anticipation term: the car is always accelerating downward,
/// so aiming exactly at the target lands slightly late. Small leads help and
/// large ones fly the car into the ceiling — 0.0 and 0.01 both play, 0.02 and
/// above die within two seconds. Two different values are used by the suite
/// because they give two genuinely different players on the same course, which
/// is what `test/verified_score_test.dart` needs to show that a better run
/// verifies as a better run.
bool Function(GameModel, int) chaseNextGapWithLead(double lead) =>
    (GameModel model, int frame) {
      if (model.state == RunState.ready) return true;
      final double carRight = GameModel.carX + GameModel.carWidth / 2;
      double target = 0.5;
      for (final Obstacle obstacle in model.obstacles) {
        if (obstacle.right > carRight - GameModel.carWidth) {
          target = obstacle.gapCentre;
          break;
        }
      }
      return model.y > target - lead;
    };

/// The suite's default player: no lead. Over the eight seeds the tests use it
/// scores between 3 and 44.
bool chaseNextGap(GameModel model, int frame) =>
    chaseNextGapWithLead(0.0)(model, frame);
