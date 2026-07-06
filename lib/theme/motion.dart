import 'package:flutter/material.dart';

/// Motion tokens. Every animated widget pulls its timing from here so the
/// app moves at one consistent, unhurried pace.
abstract final class BiteMotion {
  /// Micro-interactions: press scale, icon pops.
  static const quick = Duration(milliseconds: 160);

  /// Standard transitions: tab fade-through, cue springs.
  static const standard = Duration(milliseconds: 260);

  /// Container transforms and staggered entrances.
  static const gentle = Duration(milliseconds: 320);

  static const easeOut = Curves.easeOutCubic;
  static const spring = Curves.easeOutBack;
}

/// Whether the platform requests reduced motion. Animated widgets should
/// collapse to instant (or a plain fade) when this is true.
bool reducedMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context);

/// The swipe-up article transition: the page fades in while rising slightly,
/// and Hero flights carry the card's cover and headline up into the new
/// screen (container-transform). Collapses to a plain fade under reduced
/// motion — the destination disables its Heroes via [HeroMode] to match.
Route<T> articleRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: BiteMotion.gentle,
    reverseTransitionDuration: BiteMotion.standard,
    pageBuilder: (_, __, ___) => page,
    transitionsBuilder: (context, animation, _, child) {
      final eased =
          CurvedAnimation(parent: animation, curve: BiteMotion.easeOut);
      final faded = FadeTransition(opacity: eased, child: child);
      if (reducedMotion(context)) return faded;
      return SlideTransition(
        position: eased.drive(
            Tween(begin: const Offset(0, 0.06), end: Offset.zero)),
        child: faded,
      );
    },
  );
}
