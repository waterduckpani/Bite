import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Corner radius shared by every piece of floating chrome — tab bar, headers,
/// search fields, action bars. One value so the chrome reads as one system
/// rather than a pile of separately-rounded boxes.
const double kGlassRadius = 26;

/// A floating piece of control chrome: a real backdrop blur under a
/// translucent tint, a hairline edge, and a soft lift shadow.
///
/// This is intended ONLY for chrome that floats over content. Article content
/// stays solid and editorial and must never be wrapped in this.
///
/// Implemented with [BackdropFilter] rather than the iOS-26 Liquid Glass
/// shader: the shader renders nothing distinguishable over a near-white paper
/// background, so in light mode the header simply vanished. A blur plus a
/// translucent fill reads the same in both themes and on every platform, which
/// is what "floating chrome" needs to mean here.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = kGlassRadius,
    this.blur = 18,
    this.tint,
    this.bordered = true,
    this.elevated = true,
  });

  final Widget child;

  /// Corner radius of the surface.
  final double borderRadius;

  /// Backdrop blur sigma. Higher frosts more of what scrolls behind.
  final double blur;

  /// Overrides the theme's translucent fill. Keep the alpha below ~0.9 or the
  /// blur behind it stops being visible at all.
  final Color? tint;

  /// Draws the hairline edge that separates the glass from what's behind it.
  final bool bordered;

  /// Adds a soft drop shadow so the chrome reads as floating above content.
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    final radius = BorderRadius.circular(borderRadius);
    final fill = tint ?? bite.glass;
    // A touch of extra light along the top edge — the cheap trick that makes a
    // flat translucent panel read as a curved piece of glass.
    final sheen = Color.alphaBlend(
      Colors.white.withValues(alpha: 0.14),
      fill,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: elevated
            ? [
                BoxShadow(
                  color: bite.ink.withValues(alpha: 0.10),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ]
            : const [],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [sheen, fill],
              ),
              border: bordered
                  ? Border.all(
                      color: bite.ink.withValues(alpha: 0.08),
                      width: 0.75,
                    )
                  : null,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// A search field finished in the same glass as the tab bar and headers, so
/// the chrome on a screen matches rather than mixing a glass bar with a solid
/// input box.
class GlassSearchField extends StatelessWidget {
  const GlassSearchField({
    super.key,
    required this.controller,
    required this.hintText,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return GlassSurface(
      blur: 14,
      // Sits on the page rather than over scrolling content, so it stays flat
      // instead of casting a shadow onto the list beneath it.
      elevated: false,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: sans(size: 14, color: bite.ink),
        cursorColor: bite.accent,
        decoration: InputDecoration(
          hintText: hintText,
          hintStyle: sans(size: 14, color: bite.faint),
          prefixIcon: Icon(Icons.search, size: 20, color: bite.muted),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  icon: Icon(Icons.close, size: 18, color: bite.muted),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
      ),
    );
  }
}
