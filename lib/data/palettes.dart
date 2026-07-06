import 'dart:ui' show Color;

import '../models/article.dart';

/// Dusty, desaturated editorial cover palettes that sit quietly on the warm
/// paper background. Live articles get one deterministically by category.
const tealPalette =
    CoverPalette(Color(0xFF2E4B47), Color(0xFF52756D), Color(0xFF8BA89E));
const navyPalette =
    CoverPalette(Color(0xFF33415C), Color(0xFF5A6C8C), Color(0xFF93A2BD));
const plumPalette =
    CoverPalette(Color(0xFF4A3B55), Color(0xFF74617F), Color(0xFFA795B0));
const olivePalette =
    CoverPalette(Color(0xFF4A4D33), Color(0xFF767A55), Color(0xFFA8AC85));
const rustPalette =
    CoverPalette(Color(0xFF6E4A3A), Color(0xFF9C6F58), Color(0xFFC59D85));
const slatePalette =
    CoverPalette(Color(0xFF3E4A4E), Color(0xFF64757B), Color(0xFF97A6AB));

CoverPalette paletteFor(Category category) => switch (category) {
      Category.tech => tealPalette,
      Category.world => navyPalette,
      Category.business => olivePalette,
      Category.sports => rustPalette,
      Category.science => plumPalette,
      Category.entertainment => slatePalette,
    };
