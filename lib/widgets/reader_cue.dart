import 'package:flutter/material.dart';

import '../models/article.dart';
import '../theme/app_theme.dart';

/// Tiny pill that tells the reader where a story opens, driven off the SAME
/// flag ([Article.hasFullText]) that routes the native reader vs. the in-app
/// browser (Phase 6) — never off the source name, so the cue can't disagree
/// with where the tap actually goes.
///
///   full-text (native reader) → "Read in Bite"  (accent tint)
///   link-out                  → "Read at {source}"  (quiet neutral)
class ReaderCue extends StatelessWidget {
  const ReaderCue({super.key, required this.article});

  final Article article;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    final inBite = article.hasFullText;
    final label = inBite ? 'Read in Bite' : 'Read at ${article.source}';
    final fg = inBite ? bite.accent : bite.muted;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: (inBite ? bite.accent : bite.muted).withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            inBite ? Icons.bolt_rounded : Icons.open_in_new_rounded,
            size: 12,
            color: fg,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
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
/// Driven off [Article.hasFullText] like [ReaderCue], so the promise it makes
/// can never disagree with where the gesture actually goes.
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
