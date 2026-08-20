import 'package:cached_network_image/cached_network_image.dart';
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
            // Disk-cached, not just memory-cached. Image.network keeps decoded
            // frames in an in-memory cache that is emptied on every relaunch
            // and evicted under pressure mid-session, so the deck re-fetched
            // the same photos from the publisher's CDN over and over. We ask
            // publishers to host these images for us; re-downloading one we
            // already had is both slow for the reader and rude to the source.
            //
            // The fade stays identical: fadeInDuration/placeholder reproduce
            // what frameBuilder was doing, and errors still collapse to the
            // category gradient underneath rather than showing a broken glyph.
            CachedNetworkImage(
              imageUrl: article.imageUrl,
              fit: BoxFit.cover,
              fadeInDuration: const Duration(milliseconds: 250),
              fadeInCurve: Curves.easeOut,
              placeholderFadeInDuration: Duration.zero,
              placeholder: (_, __) => const SizedBox.shrink(),
              errorWidget: (_, __, ___) => const SizedBox.shrink(),
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
