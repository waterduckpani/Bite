import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/motion.dart';

/// Wraps interactive content with a gentle press-scale and an optional
/// selection haptic.
///
/// With [onTap] set, this widget owns the gesture. With [onTap] null it is
/// purely decorative: press tracking uses raw pointer events so the child
/// (e.g. a [FilledButton]) keeps its own tap handling and gesture-arena win.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.pressedScale = 0.97,
    this.haptic = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double pressedScale;
  final bool haptic;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final reduced = reducedMotion(context);
    Widget result = AnimatedScale(
      scale: _pressed && !reduced ? widget.pressedScale : 1.0,
      duration: BiteMotion.quick,
      curve: BiteMotion.easeOut,
      child: widget.child,
    );

    if (widget.onTap != null) {
      result = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (widget.haptic) HapticFeedback.selectionClick();
          widget.onTap!();
        },
        child: result,
      );
    }

    return Listener(
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: result,
    );
  }
}
