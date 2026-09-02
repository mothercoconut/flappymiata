/// The game's rules, as a plain-Dart value type.
///
/// WHY THERE IS NO FLAME OR FLUTTER IMPORT IN THIS FILE:
/// everything here can be exercised by `flutter test` in milliseconds with no
/// window, no canvas and no frame pump. The moment this file imports a
/// renderer, testing the rules means booting a renderer, and the rules stop
/// being cheap to check. `lib/game/README.md` states this as a directory rule.
library;

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
  static const double minY = 0.0;

  /// Bottom edge of the playfield, in normalised coordinates.
  static const double maxY = 1.0;

  /// Which of the three states this snapshot is in.
  final RunState state;

  /// Vertical position: 0.0 is the top of the playfield, 1.0 the bottom.
  final double y;

  /// Vertical speed in playfield-heights per second. Negative is upward.
  final double velocity;

  /// The initial state of every run: [RunState.ready], parked at [startY], not
  /// moving. `const` because it carries no information beyond the constants, so
  /// every caller can share one object.
  const GameModel.ready() : state = RunState.ready, y = startY, velocity = 0.0;

  /// Private, because the only legal ways to reach a new state are [tick],
  /// [flap] and [reset]. Nothing outside this file can hand itself a running
  /// game that skipped the rules.
  const GameModel._({
    required this.state,
    required this.y,
    required this.velocity,
  });

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

    // OUT-OF-BOUNDS DEATH LIVES HERE, INSIDE tick. That is a decision, and the
    // two reasons for it are:
    //
    // 1. `tick` is the only place y can change, so it is the only place the
    //    bound can be newly crossed. A separate `checkBounds()` would be a
    //    second thing every caller has to remember, and the first caller to
    //    forget it gets a car that falls silently through the floor.
    // 2. Until obstacles exist, this is the ONLY route into `dead`. A state no
    //    input can reach cannot be tested, and an untested state is where bugs
    //    wait.
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
      );
    }

    return GameModel._(
      state: RunState.playing,
      y: nextY,
      velocity: nextVelocity,
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
  /// ignores everything about the current model — a restart that carried over
  /// the last velocity would be a restart in name only.
  GameModel reset() => const GameModel.ready();

  // Value equality, so tests can compare whole models instead of field by
  // field. It is what lets "a flap while dead changes nothing" and "the same
  // inputs produce the same run" each be a single assertion.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GameModel &&
          other.state == state &&
          other.y == y &&
          other.velocity == velocity;

  @override
  int get hashCode => Object.hash(state, y, velocity);

  @override
  String toString() => 'GameModel(${state.name}, y: $y, velocity: $velocity)';
}
