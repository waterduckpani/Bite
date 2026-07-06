import 'package:flutter/material.dart';

import '../models/article.dart';
import '../theme/app_theme.dart';

/// "● The Signal · 2h ago" row with a lettermark avatar.
class SourceMark extends StatelessWidget {
  const SourceMark({super.key, required this.article, this.light = false});

  final Article article;
  final bool light;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    final ink = light ? Colors.white : bite.ink;
    return Row(
      children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: light ? Colors.white : bite.ink,
            shape: BoxShape.circle,
          ),
          child: Text(
            article.source[0],
            style: sans(
              size: 11,
              weight: FontWeight.w600,
              height: 1,
              color: light ? bite.ink : bite.paper,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          article.source,
          style: sans(size: 12.5, weight: FontWeight.w600, color: ink),
        ),
        const SizedBox(width: 6),
        Text(
          '·  ${article.timeAgo}',
          style: sans(size: 12.5, color: bite.muted),
        ),
      ],
    );
  }
}
