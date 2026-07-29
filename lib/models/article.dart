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

/// Where an article came from.
///
/// Since Phase 15.1 this decides NOTHING about how a story opens: every
/// article link-outs to the publisher, whatever produced it. [rss] is the only
/// value new rows get — [guardian] and [newsdata] persist so that rows written
/// by the retired Guardian Open Platform and NewsData ingesters still map back
/// to a known provider instead of silently becoming [mock].
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
    this.publishedAt,
    this.provider = ArticleProvider.mock,
    this.hasFullBody = false,
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

  /// When the story was published. Null for mock data, which carries a
  /// hand-written [timeAgo] label instead.
  final DateTime? publishedAt;

  final ArticleProvider provider;

  /// Mirrors `articles.full_text_available`: whether the SERVER had a full
  /// article body to summarise from, rather than only the feed description.
  ///
  /// Phase 15.1 decoupled this from routing. It used to pick the native reader
  /// vs. the in-app browser; there is no native reader now, every story
  /// link-outs, and nothing in the UI branches on this. It is carried purely
  /// so the column round-trips on upsert. Do NOT reintroduce it as a routing
  /// or presentation flag — that is exactly the split that let a card's cue
  /// disagree with where the tap went.
  final bool hasFullBody;

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
