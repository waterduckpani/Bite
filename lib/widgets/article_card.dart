import 'package:flutter/material.dart';

import '../models/article.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import 'category_chip.dart';
import 'cover_art.dart';
import 'source_mark.dart';

/// The big feed card: gradient cover with a category chip, serif headline,
/// and a source row pinned to the bottom.
class ArticleCard extends StatelessWidget {
  const ArticleCard({super.key, required this.article});

  final Article article;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
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
                            article.headline,
                            maxLines: 3,
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
                      article.snippet,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: sans(size: 13.5, height: 1.5, color: bite.muted),
                    ),
                  ),
                  SourceMark(article: article),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
