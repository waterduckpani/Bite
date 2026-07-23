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
