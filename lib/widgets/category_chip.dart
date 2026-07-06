import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Small all-caps chip, e.g. "TECH" on a card cover. Frosted paper so it
/// stays quiet on top of any cover art.
class CategoryChip extends StatelessWidget {
  const CategoryChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: bite.paper.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label.toUpperCase(), style: caps(color: bite.ink)),
    );
  }
}

/// Selectable topic pill used on onboarding and profile.
class TopicPill extends StatelessWidget {
  const TopicPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: selected ? bite.accent : bite.card,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: selected ? bite.accent : bite.border,
          width: selected ? 1 : 0.75,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Text(
              label,
              style: sans(
                size: 14,
                weight: FontWeight.w500,
                color: selected ? bite.onAccent : bite.ink,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
