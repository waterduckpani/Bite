import 'package:flutter/material.dart';

enum Category {
  tech('Tech'),
  world('World'),
  business('Business'),
  sports('Sports'),
  science('Science'),
  entertainment('Entertainment');

  const Category(this.label);
  final String label;
}

/// Where an article came from. Determines licensing: only Guardian (and
/// bundled mock) content may be rendered in the native reader; everything
/// else opens at the source.
///
/// [rss] is a Phase 14 publisher-direct story. These are LINK-OUT ONLY — Bite
/// is a referrer, not a replacement — so they always arrive with
/// [Article.hasFullText] false and route to the in-app browser.
enum ArticleProvider { guardian, newsdata, rss, mock }

/// Cover art palette. Used as the card background while a cover image loads,
/// and as the cover itself when a story has no image.
class CoverPalette {
  const CoverPalette(this.deep, this.mid, this.light);
  final Color deep;
  final Color mid;
  final Color light;

  LinearGradient get gradient => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [deep, mid, light],
      );
}

class Article {
  const Article({
    required this.id,
    required this.headline,
    required this.source,
    required this.author,
    required this.category,
    required this.imageUrl,
    required this.snippet,
    String timeAgo = '',
    required this.url,
    required this.readMinutes,
    required this.palette,
    required this.body,
    this.publishedAt,
    this.provider = ArticleProvider.mock,
    this.hasFullText = true,
    this.sourceIconUrl = '',
    this.aiSummary,
    this.aiSummaryHook,
  }) : _timeAgoLabel = timeAgo;

  final String id;
  final String headline;
  final String source;
  final String author;
  final Category category;
  final String imageUrl;
  final String snippet;
  final String url;
  final int readMinutes;
  final CoverPalette palette;

  /// Paragraphs of licensed full text. Empty when [hasFullText] is false.
  final List<String> body;

  /// When the story was published. Null for mock data, which carries a
  /// hand-written [timeAgo] label instead.
  final DateTime? publishedAt;

  final ArticleProvider provider;

  /// Whether [body] may be rendered in the native reader. False for
  /// headline-only sources (NewsData.io), whose stories open at the source.
  final bool hasFullText;

  /// The outlet's favicon, when the provider supplies one. Chrome that needs
  /// an icon falls back to a favicon service, then a lettermark.
  final String sourceIconUrl;

  /// Bite-voice summary, pre-generated server-side from licensed full text
  /// (Phase 10). Null when never generated or generation failed — the card
  /// and reader fall back to [snippet]/[body] unchanged. The client never
  /// generates these.
  final String? aiSummary;

  /// A one-line plain-spoken hook for [aiSummary]. Null alongside it.
  final String? aiSummaryHook;

  /// Whether a usable AI summary is present (both parts, non-empty).
  bool get hasSummary =>
      (aiSummary?.trim().isNotEmpty ?? false) &&
      (aiSummaryHook?.trim().isNotEmpty ?? false);

  final String _timeAgoLabel;

  /// Whether the story carries a loadable cover photo. Non-http values
  /// (empty, relative paths) fall back to the palette gradient.
  bool get hasImage => imageUrl.startsWith('http');

  /// Hero tags shared by the feed card and the reader/browser screens, so
  /// the cover and headline morph between them on swipe-up.
  String get coverHeroTag => 'article-cover-$id';
  String get headlineHeroTag => 'article-headline-$id';

  String get timeAgo {
    final at = publishedAt;
    if (at == null) return _timeAgoLabel;
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}
