import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'pressable.dart';

/// First-run coach-mark that teaches the four-gesture model. The gestures are
/// deliberately non-standard (right = read not save, down = save not dismiss),
/// so a new user is walked through them once before the deck is live. Shown
/// over the feed with the deck dimmed behind it; skippable after one view.
class GestureTutorial extends StatelessWidget {
  const GestureTutorial({super.key, required this.onDismiss});

  /// Called when the user taps "Got it" — persists the seen-version so the
  /// overlay doesn't return until [kGestureTutorialVersion] is bumped.
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Positioned.fill(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          color: bite.paper.withValues(alpha: 0.82),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
              child: Column(
                children: [
                  const Spacer(),
                  Text('Swiping in Bite',
                      style: display(size: 30, weight: 640)),
                  const SizedBox(height: 10),
                  Text(
                    'Four ways to clear a card. Right and down are both '
                    'positive — they just mean different things.',
                    textAlign: TextAlign.center,
                    style: sans(size: 14.5, color: bite.muted, height: 1.5),
                  ),
                  const SizedBox(height: 32),
                  // The four gestures, ordered by how a hand meets them:
                  // the two horizontal resolves, then save, then the
                  // non-terminal open.
                  _GestureRow(
                    icon: Icons.west_rounded,
                    badge: Icons.close_rounded,
                    color: bite.danger,
                    title: 'Swipe left — Not interested',
                    detail: 'Dismiss it. The only "less of this" signal.',
                  ),
                  _GestureRow(
                    icon: Icons.east_rounded,
                    badge: Icons.check_circle_rounded,
                    color: bite.accent,
                    title: 'Swipe right — Read, done',
                    detail: 'You got the bite and you\'re happy. Move on.',
                  ),
                  _GestureRow(
                    icon: Icons.south_rounded,
                    badge: Icons.bookmark_add_rounded,
                    color: bite.ink,
                    title: 'Swipe down — Save for later',
                    detail: 'Keep it in your Saved list.',
                  ),
                  _GestureRow(
                    icon: Icons.north_rounded,
                    badge: Icons.open_in_full_rounded,
                    color: bite.accent,
                    title: 'Swipe up or tap — Open the story',
                    detail: 'Read the full piece, then swipe to resolve.',
                  ),
                  const Spacer(),
                  Pressable(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                          minimumSize: const Size(double.infinity, 54)),
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        onDismiss();
                      },
                      child: const Text('Got it'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One labelled gesture line: a directional arrow, the matching swipe-cue
/// badge/colour, and a short description — so the overlay reads in the same
/// visual language as the live drag cues.
class _GestureRow extends StatelessWidget {
  const _GestureRow({
    required this.icon,
    required this.badge,
    required this.color,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final IconData badge;
  final Color color;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          // Arrow + cue badge stacked so the direction and its affordance read
          // together at a glance.
          SizedBox(
            width: 52,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 20, color: bite.faint),
                const SizedBox(width: 4),
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(badge, size: 16, color: color),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: sans(size: 14.5, weight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(detail, style: sans(size: 12.5, color: bite.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
