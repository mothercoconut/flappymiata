/// Reduced motion: the decoration stops, the game does not.
///
/// ============================================================================
/// WHY THIS IS NOT AN EASY MODE, AND WHY THAT DISTINCTION IS THE WHOLE POINT
/// ============================================================================
///
/// Motion on a screen makes some people ill. Vestibular disorders, migraine
/// with aura, and concussion recovery all turn a drifting background into
/// nausea or a headache, and the people it affects are not a small group. Every
/// major platform therefore ships a "reduce motion" switch, and an app that
/// ignores it is telling those players to stop playing.
///
/// The trap is what "reduce motion" gets implemented as. It is tempting to make
/// it slow the game down, or widen the gaps, or turn off the thing that keeps
/// killing the player — all of which are accessibility features of a different
/// kind, and none of which is this one. A player who turns this on is saying
/// "the scenery is making me ill", not "the game is too hard". Slowing the game
/// down would take away the thing they came for and hand them a consolation
/// prize.
///
/// So the rule this file exists to enforce is exact: REDUCED MOTION MAY NOT
/// REACH `lib/game/`. The model does not know it exists, the recorder does not
/// write it down, a run played with it on and the same run played with it off
/// are the same run frame for frame, and a record set either way verifies
/// against the other. `test/reduced_motion_test.dart` asserts precisely that,
/// the same way `test/assist_test.dart` asserts it for assist mode. What
/// changes is which pixels the backdrop draws, and nothing else.
///
/// ============================================================================
/// WHAT ACTUALLY MOVES FOR DECORATION HERE
/// ============================================================================
///
/// The backdrop's parallax: the hills sliding behind the pipes, and the clouds
/// drifting more slowly still. Both are pure decoration — they carry no
/// information about the course, they are behind everything the player has to
/// read, and stopping them removes nothing from the game.
///
/// Everything else that moves in this game is information and stays moving:
/// the pipes are the course, the car is the player, the ghost is the record
/// being raced, and the assist path is where the car is going. Stopping any of
/// those would not be reducing motion, it would be removing the game.
///
/// ============================================================================
/// THE DEFAULT COMES FROM THE PLATFORM
/// ============================================================================
///
/// A player who has already told their phone they want less motion should not
/// have to tell every app again. Flutter surfaces the operating system's own
/// switch as `MediaQuery.disableAnimations`, [SystemMotionBridge] pushes it
/// into the game, and [MotionSetting.system] — the default — follows it. The
/// in-app control exists on top of that, for the two cases the platform switch
/// cannot express: a player who wants the parallax even though the phone is set
/// to reduce motion, and a player who wants it stopped in this game only.
library;

import 'package:flutter/widgets.dart';

// =============================================================================
// The setting
// =============================================================================

/// What the player has asked for.
enum MotionSetting {
  /// Follow the platform's own accessibility switch. The default.
  system,

  /// Decoration stops, whatever the platform says.
  reduced,

  /// Decoration moves, whatever the platform says.
  full,
}

/// Whether decoration should be stopped, given the setting and what the
/// platform reports.
///
/// A PURE FUNCTION of two booleans-worth of input, kept out of the game object
/// so it can be checked exhaustively — six cases, all of them in
/// `test/reduced_motion_test.dart` — rather than inferred from a running game.
bool shouldReduceMotion({
  required MotionSetting setting,
  required bool systemDisablesAnimations,
}) {
  switch (setting) {
    case MotionSetting.system:
      return systemDisablesAnimations;
    case MotionSetting.reduced:
      return true;
    case MotionSetting.full:
      return false;
  }
}

/// The next setting when the player presses the control.
///
/// system -> reduced -> full -> system. Reduced comes first because a player
/// hunting for this control is far likelier to be looking for "stop it" than
/// for "force it on".
MotionSetting nextMotionSetting(MotionSetting current) {
  switch (current) {
    case MotionSetting.system:
      return MotionSetting.reduced;
    case MotionSetting.reduced:
      return MotionSetting.full;
    case MotionSetting.full:
      return MotionSetting.system;
  }
}

/// What the control says about itself.
///
/// On [MotionSetting.system] it names the resolved state in brackets, because
/// "AUTO" on its own answers the wrong question: somebody reading this label is
/// asking whether the background is going to move, and only the resolved state
/// answers that.
String motionSettingLabel({
  required MotionSetting setting,
  required bool systemDisablesAnimations,
}) {
  switch (setting) {
    case MotionSetting.system:
      return systemDisablesAnimations
          ? 'MOTION: AUTO (REDUCED)'
          : 'MOTION: AUTO (FULL)';
    case MotionSetting.reduced:
      return 'MOTION: REDUCED';
    case MotionSetting.full:
      return 'MOTION: FULL';
  }
}

// =============================================================================
// The decorative clock
// =============================================================================

/// How far the clouds drift, in playfield widths per second.
///
/// The world itself scrolls at 0.45 to 0.48 widths per second
/// (`Difficulty.scrollSpeedAt`). Clouds run at about a thirtieth of that, which
/// is what makes them read as far away — parallax is depth expressed as a speed
/// ratio, and nothing else.
const double cloudDriftPerSecond = 0.015;

/// How far the hills slide, in playfield widths per second. About an eighth of
/// the world's speed: nearer than the clouds, much further away than the pipes.
const double hillDriftPerSecond = 0.055;

/// The seconds of decoration that have elapsed.
///
/// SEPARATE FROM THE RUN'S OWN CLOCK, on purpose and importantly. The run
/// advances in fixed `replayFrameSeconds` steps through `ReplayRecorder`
/// because a run has to be reproducible; the backdrop has no such requirement
/// and must not be given one, because a decorative clock that fed the fixed
/// step would be a display setting with a route into the model. This
/// accumulates raw wall-clock seconds and is read by nothing but the backdrop.
class DecorClock {
  double _phase = 0.0;

  /// Seconds of decoration elapsed. Never decreases; never advances while
  /// motion is reduced.
  double get phase => _phase;

  /// Banks [dt] seconds, unless [reduced].
  ///
  /// NOT BANKED WHILE REDUCED, rather than banked and ignored. The difference
  /// shows the moment somebody turns the setting back off: with the seconds
  /// banked, the hills would jump by however long the player spent in reduced
  /// mode — which is a large sudden movement produced by the control whose
  /// entire job is to prevent large sudden movements.
  void advance(double dt, {required bool reduced}) {
    if (reduced) return;
    if (!dt.isFinite || dt <= 0) return;
    _phase += dt;
  }

  /// Back to the start.
  void reset() {
    _phase = 0.0;
  }
}

/// Where a parallax layer has slid to, as a fraction of one playfield width in
/// `[0, 1)`.
///
/// Wrapped rather than unbounded so the caller can draw one tile at this offset
/// and a second one a width to its right and have the seam never arrive. Dart's
/// `%` is already non-negative for a positive divisor, so a negative phase — a
/// clock that somehow ran backwards — cannot produce a negative offset here.
double parallaxOffset(double phase, double speedPerSecond) {
  if (!phase.isFinite) return 0.0;
  return (phase * speedPerSecond) % 1.0;
}

// =============================================================================
// The platform bridge
// =============================================================================

/// Anything that wants to be told what the platform's motion switch says.
///
/// One setter, so `test/reduced_motion_test.dart` can drive [SystemMotionBridge]
/// with a two-line fake instead of booting a game.
abstract class MotionHost {
  /// Whether the operating system has asked apps to reduce motion.
  set systemDisablesAnimations(bool value);
}

/// Reads `MediaQuery.disableAnimations` and pushes it into [host].
///
/// WHY A WIDGET AND NOT A LOOKUP IN THE GAME: `MediaQuery` is an inherited
/// widget, so it can only be read from a `BuildContext`, and a `FlameGame` does
/// not have one. It also CHANGES — a player can flip the switch in the system
/// settings while the app is open — and `didChangeDependencies` is what fires
/// when it does. A one-off read in `main()` would get the right answer once and
/// then be wrong for the rest of the session.
class SystemMotionBridge extends StatefulWidget {
  /// Who to tell.
  final MotionHost host;

  /// The rest of the app.
  final Widget child;

  const SystemMotionBridge({
    super.key,
    required this.host,
    required this.child,
  });

  @override
  State<SystemMotionBridge> createState() => _SystemMotionBridgeState();
}

class _SystemMotionBridgeState extends State<SystemMotionBridge> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.host.systemDisablesAnimations =
        MediaQuery.disableAnimationsOf(context);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
