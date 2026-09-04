/// Tests for the headless driver in `tool/headless_sim.dart`.
///
/// The driver is the only thing that decides what "one frame of play" means —
/// whether a tap lands before or after that frame's physics. Everything else
/// (the fairness prover, every witness replay) is stated in terms of it, so if
/// it drifts they all quietly start describing a different game.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/game/game_model.dart';

import '../tool/headless_sim.dart';

void main() {
  group('headless driver', () {
    test('a run that never taps never starts', () {
      // `tick` returns the receiver untouched while the state is `ready`, so a
      // policy that never flaps produces a run in which literally nothing
      // happens. This is not a driver bug — it is the property the fairness
      // prover relies on when it starts its clock at the first tap.
      final SimResult r = runHeadless(policy: neverFlap, maxFrames: 600);
      expect(r.frames, 600);
      expect(r.finalModel.state, RunState.ready);
      expect(r.finalModel.y, GameModel.startY);
      expect(r.outcome, SimOutcome.survived);
    });

    test('tapping once and then never again drops out of the floor', () {
      final SimResult r = runHeadless(policy: startThenDrop, maxFrames: 600);
      expect(r.outcome, SimOutcome.leftPlayfield);
      expect(r.finalModel.y, GameModel.maxY);
      expect(r.flaps, 1);
    });

    test('tapping every frame climbs out through the ceiling', () {
      // Because a flap ASSIGNS velocity, mashing does not accelerate: the car
      // climbs at a fixed rate and leaves through the top.
      final SimResult r = runHeadless(policy: alwaysFlap, maxFrames: 600);
      expect(r.outcome, SimOutcome.leftPlayfield);
      expect(r.finalModel.y, GameModel.minY);
    });

    test('the driver stops the moment the model dies', () {
      final SimResult r = runHeadless(policy: startThenDrop, maxFrames: 100000);
      expect(r.finalModel.state, RunState.dead);
      // One more tick would have been wasted work, and worse, would have made
      // "frames survived" mean something different from what it says.
      expect(r.frames, lessThan(100000));
    });

    test('the driver-side obstacle count agrees with the model score', () {
      // Two independent counters: the model sets its own `scored` flag, the
      // driver watches obstacles cross behind the car. They have to match, or
      // one of them is wrong.
      //
      // Every gap is pinned to mid-field so a crude altitude hold really does
      // get through them — a run that scores nothing would make this assertion
      // pass for the wrong reason.
      final SimResult r = runHeadless(
        start: GameModel.ready(gapCentreFor: (int index) => 0.5),
        policy: holdAltitude(0.5),
        maxFrames: 4000,
      );
      expect(r.score, greaterThan(5));
      expect(r.obstaclesPassed, r.score);
    });

    test('a recorded input sequence replays to exactly the same run', () {
      // This is what makes a fairness witness worth anything: the inputs, on
      // their own, reproduce the run. Nothing hidden in the policy.
      final SimResult first = runHeadless(
        policy: chaseGap(),
        maxFrames: 900,
        recordInputs: true,
      );
      final SimResult second = replay(first.inputs!);

      expect(second.frames, first.frames);
      expect(second.score, first.score);
      expect(second.outcome, first.outcome);
      expect(second.finalModel, first.finalModel);
    });

    test('untilScore stops the run as soon as the target is reached', () {
      final SimResult r = runHeadless(
        start: GameModel.ready(gapCentreFor: (int index) => 0.5),
        policy: holdAltitude(0.5),
        maxFrames: 20000,
        untilScore: 3,
      );
      expect(r.alive, isTrue);
      expect(r.score, 3);
    });
  });
}
