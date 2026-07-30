import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';

/// What a [SwipeHint] is asking for.
enum HintGesture { left, right, up, down, tap }

/// A looping "do this" hint: a fingertip puck that travels in the target
/// direction, over and over, until the user actually does it.
///
/// The loop is the teaching device. A one-shot animation played on entry is
/// missed by anyone who looked away, and a static arrow is a diagram rather
/// than an instruction. This keeps going for as long as the step is unanswered,
/// which is exactly as long as the user needs it.
///
/// Purely decorative: it never handles a pointer, so the real gesture goes
/// straight through it to the card underneath.
class SwipeHint extends StatefulWidget {
  const SwipeHint({
    super.key,
    required this.gesture,
    this.color,
    this.travel = 88,
  });

  final HintGesture gesture;

  /// Tint of the puck and its trail. Defaults to the accent; the reject step
  /// passes the danger colour so the hint agrees with the cue it will produce.
  final Color? color;

  /// How far the puck travels from rest, in logical pixels.
  final double travel;

  @override
  State<SwipeHint> createState() => _SwipeHintState();
}

class _SwipeHintState extends State<SwipeHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1650),
  );

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion gets a still puck rather than a loop, PARKED AT THE END
    // OF ITS TRAVEL rather than left at zero. At zero the puck is mid-fade-in
    // and therefore invisible, which would answer "no animations please" with
    // "no instruction either". Resolved here (not initState) because it needs
    // MediaQuery, and guarded so a theme change doesn't restart the loop
    // mid-step.
    if (_started) return;
    _started = true;
    if (reducedMotion(context)) {
      _c.value = 0.4;
    } else {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Offset get _unit => switch (widget.gesture) {
        HintGesture.left => const Offset(-1, 0),
        HintGesture.right => const Offset(1, 0),
        HintGesture.up => const Offset(0, -1),
        HintGesture.down => const Offset(0, 1),
        HintGesture.tap => Offset.zero,
      };

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    final color = widget.color ?? bite.accent;
    return IgnorePointer(
      child: Center(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = _c.value;
            // Travel eases out over the first two-thirds, then the puck fades
            // and the next pass begins. The gap is deliberate: a puck that
            // never rests reads as decoration, not as a repeated instruction.
            final progress = Curves.easeOutCubic.transform((t / 0.66).clamp(0.0, 1.0));
            final fadeIn = (t / 0.12).clamp(0.0, 1.0);
            final fadeOut = 1 - ((t - 0.66) / 0.34).clamp(0.0, 1.0);
            final opacity = fadeIn * fadeOut;
            final offset = _unit * (widget.travel * progress);
            // The tap hint has nowhere to travel, so it pulses instead.
            final scale = widget.gesture == HintGesture.tap
                ? 1 + 0.35 * progress
                : 1.0;
            return Transform.translate(
              offset: offset,
              child: Opacity(
                opacity: opacity.clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: scale,
                  child: _Puck(color: color, gesture: widget.gesture),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The fingertip itself: a soft halo with a solid core, plus the directional
/// arrow so the hint is legible even in a single frame (a screenshot, or with
/// animations switched off).
class _Puck extends StatelessWidget {
  const _Puck({required this.color, required this.gesture});

  final Color color;
  final HintGesture gesture;

  @override
  Widget build(BuildContext context) {
    final icon = switch (gesture) {
      HintGesture.left => Icons.west_rounded,
      HintGesture.right => Icons.east_rounded,
      HintGesture.up => Icons.north_rounded,
      HintGesture.down => Icons.south_rounded,
      HintGesture.tap => Icons.touch_app_rounded,
    };
    return Container(
      width: 76,
      height: 76,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.18),
        border: Border.all(color: color.withValues(alpha: 0.55), width: 1.5),
      ),
      child: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        child: Icon(icon, size: 22, color: Colors.white),
      ),
    );
  }
}

/// A spotlight over the real UI: everything dims except one cut-out rectangle,
/// which keeps its full brightness and gets a breathing accent ring.
///
/// Deliberately non-interactive. The scrim absorbs nothing, so the highlighted
/// control is tapped for real rather than through a simulation of itself, and a
/// tap that lands somewhere else still reaches its widget. The screen behind
/// decides what to do about a wrong tap, which is how a wrong tap can be
/// answered with a nudge instead of a dead zone.
class SpotlightScrim extends StatefulWidget {
  const SpotlightScrim({super.key, required this.hole, this.radius = 20});

  /// The un-dimmed rectangle, in global coordinates. Null dims everything,
  /// which is what the first frame looks like before the target is measured.
  final Rect? hole;

  final double radius;

  @override
  State<SpotlightScrim> createState() => _SpotlightScrimState();
}

class _SpotlightScrimState extends State<SpotlightScrim>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!reducedMotion(context)) _pulse.repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) => CustomPaint(
          size: Size.infinite,
          painter: _SpotlightPainter(
            hole: widget.hole,
            radius: widget.radius,
            scrim: bite.scrim,
            ring: bite.accent,
            pulse: _pulse.value,
          ),
        ),
      ),
    );
  }
}

class _SpotlightPainter extends CustomPainter {
  const _SpotlightPainter({
    required this.hole,
    required this.radius,
    required this.scrim,
    required this.ring,
    required this.pulse,
  });

  final Rect? hole;
  final double radius;
  final Color scrim;
  final Color ring;
  final double pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final screen = Offset.zero & size;
    final target = hole;
    if (target == null) {
      canvas.drawRect(screen, Paint()..color = scrim);
      return;
    }
    final rrect = RRect.fromRectAndRadius(target, Radius.circular(radius));
    // Even-odd over the whole screen: one fill, one hole, no seams between
    // four separately-drawn edge rectangles.
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(screen)
      ..addRRect(rrect);
    canvas.drawPath(path, Paint()..color = scrim);
    canvas.drawRRect(
      rrect.inflate(2 + 2 * pulse),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = ring.withValues(alpha: 0.85 - 0.35 * pulse),
    );
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) =>
      old.hole != hole ||
      old.pulse != pulse ||
      old.scrim != scrim ||
      old.ring != ring ||
      old.radius != radius;
}

/// A breathing accent ring around a control that is small enough to point at
/// in place, where a travelling puck would swamp it.
///
/// Wraps its child rather than overlaying the screen, so the control keeps its
/// own hit target and its own tap handling: the ring is decoration around a
/// live button, not a stand-in for one.
class PulseRing extends StatefulWidget {
  const PulseRing({super.key, required this.child, this.active = true});

  final Widget child;

  /// False once the control has been used, so the ring stops asking.
  final bool active;

  @override
  State<PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<PulseRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!reducedMotion(context)) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        if (widget.active)
          IgnorePointer(
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                final t = Curves.easeOut.transform(_c.value);
                return Transform.scale(
                  scale: 1 + 0.55 * t,
                  child: Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: bite.accent.withValues(alpha: 0.9 * (1 - t)),
                        width: 2,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        widget.child,
      ],
    );
  }
}
