import 'package:flutter/material.dart';

import '../models/article.dart';
import '../theme/app_theme.dart';
import 'cover_art.dart';

/// Compact list card used on the Saved and Discover screens.
class SavedTile extends StatelessWidget {
  const SavedTile({super.key, required this.article, required this.onTap});

  final Article article;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Material(
      color: bite.card,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: bite.border, width: 0.75),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 56,
                height: 56,
                child: CoverArt(
                  article: article,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      article.category.label.toUpperCase(),
                      style: caps(size: 9, color: bite.accent),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      article.headline,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: display(size: 16.5, weight: 560, height: 1.18),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${article.source}  ·  ${article.timeAgo}',
                      style: sans(size: 11.5, color: bite.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
