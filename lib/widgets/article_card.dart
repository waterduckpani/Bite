import 'package:flutter/material.dart';

import '../models/article.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import 'category_chip.dart';
import 'cover_art.dart';
import 'reader_cue.dart';
import 'source_mark.dart';

/// The big feed card: gradient cover with a category chip, serif headline,
/// and a source row pinned to the bottom.
class ArticleCard extends StatelessWidget {
  const ArticleCard({super.key, required this.article});

  final Article article;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    // When a Bite summary is present, the punchy hook leads (it morphs into
    // the fuller real headline in the reader) and the summary is the body.
    // Otherwise fall back to the publisher headline + standfirst, unchanged.
    final hasSummary = article.hasSummary;
    final leadLine = hasSummary ? article.aiSummaryHook! : article.headline;
    final bodyLine = hasSummary ? article.aiSummary! : article.snippet;
    // Link-out cards spend a row on the persistent "Swipe up to read at …"
    // cue, so the text above it gets one line less each. Without this the
    // headline is handed less height than its maxLines needs and hard-CLIPS
    // mid-word instead of ellipsising — Text only ellipsises at maxLines, not
    // at the height it was actually given.
    final textLines = article.hasFullText ? 3 : 2;
    return Container(
      decoration: BoxDecoration(
        color: bite.card,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: bite.border, width: 0.75),
        boxShadow: [
          BoxShadow(
            color: bite.ink.withValues(alpha: 0.04),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 11,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Hero pair with the reader/browser: on swipe-up the cover
                // and headline morph up into the opened screen.
                HeroMode(
                  enabled: !reducedMotion(context),
                  child: Hero(
                    tag: article.coverHeroTag,
                    child: CoverArt(article: article, showCredit: true),
                  ),
                ),
                Positioned(
                  top: 14,
                  left: 14,
                  child: CategoryChip(label: article.category.label),
                ),
                // Followed-state marker (Phase 13): shows this story is already
                // tracked, so it reads as followed and can't be double-followed.
                if (AppScope.of(context).isFollowing(article.id))
                  const Positioned(top: 14, right: 14, child: _FollowingBadge()),
              ],
            ),
          ),
          Expanded(
            flex: 9,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Flexible (not fixed) so a long headline gives way instead
                  // of overflowing the card on short screens.
                  Flexible(
                    child: HeroMode(
                      enabled: !reducedMotion(context),
                      child: Hero(
                        tag: article.headlineHeroTag,
                        child: Material(
                          type: MaterialType.transparency,
                          child: Text(
                            leadLine,
                            maxLines: textLines,
                            overflow: TextOverflow.ellipsis,
                            style:
                                display(size: 26, weight: 560, height: 1.14),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: Text(
                      bodyLine,
                      maxLines: textLines,
                      overflow: TextOverflow.ellipsis,
                      style: sans(size: 13.5, height: 1.5, color: bite.muted),
                    ),
                  ),
                  // Phase 14: link-out stories carry a persistent, prominent
                  // route to the publisher directly under the bite. Full-text
                  // stories keep the compact "Read in Bite" pill in the source
                  // row below instead.
                  if (!article.hasFullText) ...[
                    LinkOutCue(article: article),
                    const SizedBox(height: 10),
                  ],
                  Row(
                    children: [
                      Expanded(child: SourceMark(article: article)),
                      if (article.hasFullText) ...[
                        const SizedBox(width: 8),
                        ReaderCue(article: article),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small "Following" pill shown on the cover of a tracked story.
class _FollowingBadge extends StatelessWidget {
  const _FollowingBadge();

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bite.accent,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.notifications_active, size: 12, color: bite.onAccent),
          const SizedBox(width: 4),
          Text('Following', style: caps(size: 9, color: bite.onAccent)),
        ],
      ),
    );
  }
}
