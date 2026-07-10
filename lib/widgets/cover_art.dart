import 'package:flutter/material.dart';

import '../models/article.dart';

/// Article cover: the real photo when the story has one, fading in over the
/// category's editorial gradient, which also stands in while loading, on
/// error, and for stories with no image. A faint credit line in the corner
/// attributes the source.
class CoverArt extends StatelessWidget {
  const CoverArt({
    super.key,
    required this.article,
    this.borderRadius = BorderRadius.zero,
    this.showCredit = false,
  });

  final Article article;
  final BorderRadius borderRadius;
  final bool showCredit;

  @override
  Widget build(BuildContext context) {
    final hasImage = article.hasImage;
    return ClipRRect(
      borderRadius: borderRadius,
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(gradient: article.palette.gradient),
          ),
          if (hasImage)
            Image.network(
              article.imageUrl,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              frameBuilder: (context, child, frame, syncLoaded) => syncLoaded
                  ? child
                  : AnimatedOpacity(
                      opacity: frame == null ? 0 : 1,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                      child: child,
                    ),
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          if (showCredit)
            Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  article.source.toLowerCase(),
                  style: TextStyle(
                    fontFamily: 'Menlo',
                    fontSize: 9,
                    color: Colors.white.withValues(alpha: 0.6),
                    letterSpacing: 0.5,
                    shadows: const [
                      Shadow(color: Colors.black45, blurRadius: 6),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
