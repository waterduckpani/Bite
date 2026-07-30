import 'package:flutter/material.dart';

/// Bite's design tokens: airy paper background, near-black ink, and a single
/// soft sage accent. Everything colour-related lives here — widgets resolve
/// the active palette via `context.bite` and must not hardcode colours.
class BiteColors extends ThemeExtension<BiteColors> {
  const BiteColors({
    required this.paper,
    required this.ink,
    required this.accent,
    required this.onAccent,
    required this.body,
    required this.muted,
    required this.faint,
    required this.border,
    required this.card,
    required this.glass,
    required this.scrim,
    required this.onScrim,
    required this.danger,
  });

  /// Scaffold / page background.
  final Color paper;

  /// Primary text.
  final Color ink;

  /// The one accent (sage). Swap it here to retheme the whole app.
  final Color accent;

  /// Text/icons sitting on top of [accent].
  final Color onAccent;

  /// Reading copy that sits under a headline — the bite on a card, a timeline
  /// entry's summary. Deliberately much closer to [ink] than [muted]: this is
  /// the second most important thing on a card, and [muted] was too light to
  /// hold that job.
  final Color body;

  /// Secondary text — labels, meta lines, attribution.
  final Color muted;

  /// Tertiary text, placeholders, disabled glyphs.
  final Color faint;

  /// Hairline dividers and outlines.
  final Color border;

  /// Raised card surface.
  final Color card;

  /// Fill for floating chrome (tab bar, headers, search field) drawn over a
  /// blurred backdrop. Translucent on purpose — the alpha IS the effect, so
  /// this must never be swapped for an opaque colour.
  final Color glass;

  /// Dimming layer behind a modal or a coach mark. DARK IN BOTH THEMES, which
  /// is why it cannot be derived from [ink]: ink is near-white in dark mode, so
  /// a scrim built from it lightens the screen instead of dimming it and
  /// inverts the figure and ground of anything spotlighted through it.
  final Color scrim;

  /// Text and glyphs drawn ON [scrim]. Light in both themes, for the same
  /// reason: what sits on the scrim is over a dark layer either way.
  final Color onScrim;

  /// Destructive affordances (delete swipe, skip cue).
  final Color danger;

  static const light = BiteColors(
    paper: Color(0xFFFBFAF7),
    ink: Color(0xFF1C1B19),
    accent: Color(0xFF86A797),
    onAccent: Color(0xFFFCFDFC),
    body: Color(0xFF474139),
    muted: Color(0xFF8A857C),
    faint: Color(0xFFB3ADA2),
    border: Color(0xFFEAE7E0),
    card: Color(0xFFFFFFFF),
    glass: Color(0xC4FFFFFF),
    scrim: Color(0xA31C1B19),
    onScrim: Color(0xFFFBFAF7),
    danger: Color(0xFFC07B6A),
  );

  static const dark = BiteColors(
    paper: Color(0xFF161514),
    ink: Color(0xFFECE9E3),
    accent: Color(0xFF8FB3A2),
    onAccent: Color(0xFF12211B),
    body: Color(0xFFCBC5BB),
    muted: Color(0xFF9A948A),
    faint: Color(0xFF6B665E),
    border: Color(0xFF2C2A27),
    card: Color(0xFF1F1E1C),
    glass: Color(0xC42B2926),
    scrim: Color(0xB3060605),
    onScrim: Color(0xFFECE9E3),
    danger: Color(0xFFC98A79),
  );

  static BiteColors of(BuildContext context) =>
      Theme.of(context).extension<BiteColors>()!;

  @override
  BiteColors copyWith({
    Color? paper,
    Color? ink,
    Color? accent,
    Color? onAccent,
    Color? body,
    Color? muted,
    Color? faint,
    Color? border,
    Color? card,
    Color? glass,
    Color? scrim,
    Color? onScrim,
    Color? danger,
  }) {
    return BiteColors(
      paper: paper ?? this.paper,
      ink: ink ?? this.ink,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      body: body ?? this.body,
      muted: muted ?? this.muted,
      faint: faint ?? this.faint,
      border: border ?? this.border,
      card: card ?? this.card,
      glass: glass ?? this.glass,
      scrim: scrim ?? this.scrim,
      onScrim: onScrim ?? this.onScrim,
      danger: danger ?? this.danger,
    );
  }

  @override
  BiteColors lerp(BiteColors? other, double t) {
    if (other == null) return this;
    return BiteColors(
      paper: Color.lerp(paper, other.paper, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      body: Color.lerp(body, other.body, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      faint: Color.lerp(faint, other.faint, t)!,
      border: Color.lerp(border, other.border, t)!,
      card: Color.lerp(card, other.card, t)!,
      glass: Color.lerp(glass, other.glass, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
      onScrim: Color.lerp(onScrim, other.onScrim, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
    );
  }
}

extension BiteThemeContext on BuildContext {
  BiteColors get bite => BiteColors.of(this);
}

/// Display style for headlines and reading copy. Inter is bundled as a
/// variable font, so weights are selected via the `wght` axis rather than
/// [FontWeight]. Large sizes automatically get tight tracking so headlines
/// feel set, not typed; pass [spacing] to override. When [color] is null the
/// style inherits the ambient text colour, which keeps it dark-mode safe.
TextStyle display({
  double size = 24,
  double weight = 640,
  double height = 1.15,
  Color? color,
  double? spacing,
}) {
  return TextStyle(
    fontFamily: 'Inter',
    fontSize: size,
    height: height,
    color: color,
    // ~ -2% of the font size once headlines get large, flat below that.
    letterSpacing: spacing ?? (size >= 20 ? size * -0.022 : -0.1),
    fontVariations: [
      FontVariation('wght', weight),
      FontVariation('opsz', size.clamp(14, 32)),
    ],
  );
}

/// Inter for small UI labels, captions and the tab bar. Same face as
/// [display], calmer sizes and neutral tracking.
TextStyle sans({
  double size = 13,
  FontWeight weight = FontWeight.w400,
  double height = 1.4,
  Color? color,
  double? spacing,
  double? wght,
}) {
  return TextStyle(
    fontFamily: 'Inter',
    fontSize: size,
    height: height,
    color: color,
    letterSpacing: spacing,
    fontVariations: [
      // Inter is variable, so the axis takes any value — [wght] exists for the
      // in-between weights [FontWeight] can't name (450 for reading copy that
      // needs a touch more presence than regular without going semibold).
      FontVariation('wght', wght ?? weight.value.toDouble()),
      FontVariation('opsz', size.clamp(14, 32)),
    ],
  );
}

/// Small all-caps label style used for category chips and section headers.
TextStyle caps({double size = 10, Color? color}) {
  return TextStyle(
    fontFamily: 'Inter',
    fontSize: size,
    color: color,
    fontVariations: const [FontVariation('wght', 620)],
    letterSpacing: 1.6,
  );
}

ThemeData buildBiteTheme(Brightness brightness) {
  final bite =
      brightness == Brightness.light ? BiteColors.light : BiteColors.dark;

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: bite.paper,
    colorScheme: ColorScheme.fromSeed(
      brightness: brightness,
      seedColor: bite.accent,
      primary: bite.accent,
      onPrimary: bite.onAccent,
      surface: bite.paper,
      onSurface: bite.ink,
    ),
    splashFactory: NoSplash.splashFactory,
  );

  return base.copyWith(
    extensions: [bite],
    textTheme: base.textTheme.apply(
      bodyColor: bite.ink,
      displayColor: bite.ink,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: bite.paper,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: bite.ink,
    ),
    dividerTheme: DividerThemeData(color: bite.border, thickness: 0.75),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: bite.ink,
      contentTextStyle: sans(size: 13.5, color: bite.paper),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: bite.accent,
        foregroundColor: bite.onAccent,
        minimumSize: const Size.fromHeight(52),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        textStyle: sans(size: 15.5, weight: FontWeight.w600, spacing: 0.2),
      ),
    ),
  );
}
