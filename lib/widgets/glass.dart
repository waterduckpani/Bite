import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

import '../theme/app_theme.dart';

/// Whether the running engine can render the real iOS-26 "Liquid Glass"
/// material.
///
/// We only opt in on Apple platforms (iOS 26 / macOS) whose Impeller/Metal
/// backend can execute fragment shaders. On Android, web and older iOS on
/// Skia we deliberately fall back to a solid, non-translucent surface so
/// nothing breaks. [ui.ImageFilter.isShaderFilterSupported] is the same
/// capability flag `liquid_glass_renderer` checks internally.
bool get liquidGlassSupported {
  final onApple = defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;
  return onApple && ui.ImageFilter.isShaderFilterSupported;
}

/// A floating piece of control chrome finished in Liquid Glass where the
/// platform supports it, and a solid opaque surface everywhere else.
///
/// This is intended ONLY for chrome that floats over content — tab bars,
/// headers, action bars, swipe cues. Article content stays solid and
/// editorial and must never be wrapped in this.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = 24,
    this.blur = 8,
    this.thickness = 16,
    this.tint,
    this.solidColor,
    this.solidBorder = true,
    this.elevated = true,
  });

  final Widget child;

  /// Corner radius of the glass squircle (and of the solid fallback).
  final double borderRadius;

  /// Frost amount of the glass. Ignored by the solid fallback.
  final double blur;

  /// Glass thickness — thicker refracts the background more. Ignored by the
  /// solid fallback.
  final double thickness;

  /// Glass tint; its alpha controls tint strength. Defaults to a faint white
  /// frost. Ignored by the solid fallback.
  final Color? tint;

  /// Opaque colour used for the non-glass fallback. Defaults to the theme's
  /// paper colour.
  final Color? solidColor;

  /// Whether the solid fallback draws a hairline border.
  final bool solidBorder;

  /// Adds a soft drop shadow so the chrome reads as floating above content.
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    final radius = BorderRadius.circular(borderRadius);
    // Airy chrome floats on a whisper of shadow, not a heavy drop.
    final shadow = elevated
        ? <BoxShadow>[
            BoxShadow(
              color: bite.ink.withValues(alpha: 0.05),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ]
        : const <BoxShadow>[];

    if (!liquidGlassSupported) {
      // Clean fallback: fully opaque, non-translucent chrome.
      return DecoratedBox(
        decoration: BoxDecoration(
          color: solidColor ?? bite.paper,
          borderRadius: radius,
          border: solidBorder
              ? Border.all(color: bite.border, width: 0.75)
              : null,
          boxShadow: shadow,
        ),
        child: ClipRRect(borderRadius: radius, child: child),
      );
    }

    // The real thing: a self-contained Liquid Glass layer shaped as a
    // rounded superellipse. The child is drawn crisply on top of the glass
    // (glassContainsChild defaults to false).
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: radius, boxShadow: shadow),
      child: LiquidGlass.withOwnLayer(
        shape: LiquidRoundedSuperellipse(borderRadius: borderRadius),
        clipBehavior: Clip.antiAlias,
        settings: LiquidGlassSettings(
          blur: blur,
          thickness: thickness,
          glassColor: tint ?? const Color(0x1AFFFFFF),
          lightIntensity: 0.7,
          ambientStrength: 0.12,
          refractiveIndex: 1.25,
          saturation: 1.2,
        ),
        child: child,
      ),
    );
  }
}
