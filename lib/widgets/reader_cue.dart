import 'package:flutter/material.dart';

import '../models/article.dart';
import '../theme/app_theme.dart';

/// Tiny pill naming where a story opens: **"Read at {publisher}"**, always.
///
/// It used to branch on [Article.hasFullBody] — "Read in Bite" for full-text
/// stories, "Read at {source}" for the rest. Phase 15.1 removed the native
/// reader, so there is nothing to branch on: every story opens at the
/// publisher. The branch is gone rather than left pointing at a flag that no
/// longer decides anything, which is what let the cue and the tap disagree.
class ReaderCue extends StatelessWidget {
  const ReaderCue({super.key, required this.article});

  final Article article;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    final fg = bite.muted;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: bite.muted.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.open_in_new_rounded, size: 12, color: fg),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              'Read at ${article.source}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: sans(size: 11, weight: FontWeight.w600, color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

/// The Phase 14 link-out affordance: a full-width, persistent
/// **"Swipe up to read at {publisher}"** bar that sits directly under the bite
/// on the feed card.
///
/// Deliberately prominent rather than subtle. Bite is a REFERRER, not a
/// replacement: the 80-word bite is meant to inform, not complete, so the route
/// to the publisher's own page has to read as the obvious next step rather than
/// a hint you could miss. Tap is equivalent to swipe-up (Phase 11), and both
/// open the publisher's real page in the in-app browser.
///
/// Shown on EVERY card since Phase 15.1 — there is no other kind of story —
/// so the promise it makes cannot disagree with where the gesture goes.
class LinkOutCue extends StatelessWidget {
  const LinkOutCue({super.key, required this.article});

  final Article article;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: bite.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: bite.accent.withValues(alpha: 0.22),
          width: 0.75,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.arrow_upward_rounded, size: 15, color: bite.accent),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              'Swipe up to read at ${article.source}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: sans(
                size: 12.5,
                weight: FontWeight.w600,
                color: bite.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
