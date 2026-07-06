import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/palettes.dart';
import '../data/source_quality.dart';
import '../models/article.dart';

/// NewsData.io client. The free tier licenses headlines and snippets only —
/// these articles carry no body and MUST open at the publisher's site, never
/// in the native reader.
///
/// Source quality is enforced twice: on the request (`prioritydomain=top`
/// keeps us to the top 10% of domains; `excludedomain` drops the worst
/// offenders server-side) and on the response (datatype, blocklist, and
/// quality ranking — see [SourceQuality]).
class NewsdataApi {
  NewsdataApi(this.apiKey, {http.Client? client})
      : _client = client ?? http.Client();

  final String apiKey;
  final http.Client _client;

  static const _host = 'newsdata.io';

  /// NewsData category slugs → Bite categories. The API accepts at most five
  /// category filters per request; entertainment coverage comes from the
  /// Guardian's culture sections instead.
  static const _categoryMap = <String, Category>{
    'technology': Category.tech,
    'world': Category.world,
    'business': Category.business,
    'sports': Category.sports,
    'science': Category.science,
    'entertainment': Category.entertainment,
  };
  static const _requested = 'technology,business,science,sports,world';

  /// Whether the plan accepts the quality filter params. Flipped off after
  /// one rejected request so we degrade to client-side filtering only
  /// instead of losing the source.
  bool _qualityParamsOk = true;

  /// Pages fetched per refresh (10 stories each, 1 credit each). Three pages
  /// keep NewsData roughly at parity with the Guardian's 30 after filtering.
  static const _pages = 3;

  Future<List<Article>> fetchLatest() async {
    final ranked = <_Ranked>[];
    String? page;
    for (var i = 0; i < _pages; i++) {
      final json = await _fetchPage(page);
      final results =
          ((json['results'] as List?) ?? const []).cast<Map<String, dynamic>>();
      for (final item in results) {
        if (_map(item) case final article?) ranked.add(article);
      }
      page = json['nextPage'] as String?;
      if (page == null) break;
    }

    // Quality order: curated-trusted outlets first, then stories with real
    // cover images, then the API's own authority score (lower = better).
    ranked.sort((a, b) {
      if (a.trusted != b.trusted) return a.trusted ? -1 : 1;
      if (a.hasImage != b.hasImage) return a.hasImage ? -1 : 1;
      return a.sourcePriority.compareTo(b.sourcePriority);
    });
    return [for (final r in ranked) r.article];
  }

  Future<Map<String, dynamic>> _fetchPage(String? page) async {
    try {
      return await _request(page, withQualityParams: _qualityParamsOk);
    } on http.ClientException {
      if (!_qualityParamsOk) rethrow;
      // Plan may not accept prioritydomain/excludedomain; retry without
      // them and rely on client-side filtering.
      _qualityParamsOk = false;
      return _request(page, withQualityParams: false);
    }
  }

  Future<Map<String, dynamic>> _request(String? page,
      {required bool withQualityParams}) async {
    final uri = Uri.https(_host, '/api/1/latest', {
      'apikey': apiKey,
      'language': 'en',
      'category': _requested,
      'removeduplicate': '1',
      if (withQualityParams) 'prioritydomain': 'top',
      if (withQualityParams)
        'excludedomain': SourceQuality.excludeOnRequest.join(','),
      if (page != null) 'page': page,
    });

    final res = await _client.get(uri).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) {
      throw http.ClientException('NewsData HTTP ${res.statusCode}', uri);
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    if (json['status'] != 'success') {
      throw http.ClientException('NewsData status ${json['status']}', uri);
    }
    return json;
  }

  _Ranked? _map(Map<String, dynamic> item) {
    if (item['duplicate'] == true) return null;
    // Real reporting only — no blogs, press releases, or forum posts.
    final datatype = item['datatype'] as String?;
    if (datatype != null && datatype != 'news') return null;

    final headline = (item['title'] as String?)?.trim() ?? '';
    final url = item['link'] as String? ?? '';
    if (headline.isEmpty || url.isEmpty) return null;

    final domain = SourceQuality.domainOf(
        (item['source_url'] as String?) ?? url);
    if (SourceQuality.isBlocked(domain)) return null;

    final categories =
        ((item['category'] as List?) ?? const []).cast<String>();
    final category = categories
        .map((c) => _categoryMap[c])
        .whereType<Category>()
        .firstOrNull;
    if (category == null) return null;

    final source =
        (item['source_name'] as String?) ?? (item['source_id'] as String? ?? '');
    final creators = ((item['creator'] as List?) ?? const []).cast<String>();
    final imageUrl = _validImageUrl(item['image_url'] as String?);

    // pubDate arrives as "2026-07-05 18:44:00" in UTC.
    final pubDate = (item['pubDate'] as String?)?.replaceFirst(' ', 'T');
    final publishedAt =
        pubDate == null ? null : DateTime.tryParse('${pubDate}Z');

    return _Ranked(
      Article(
        id: 'newsdata:${item['article_id']}',
        headline: headline,
        source: source.isEmpty ? 'News' : source,
        author: creators.firstOrNull ?? (source.isEmpty ? 'News' : source),
        category: category,
        imageUrl: imageUrl,
        snippet: (item['description'] as String?)?.trim() ?? '',
        url: url,
        readMinutes: 2,
        palette: paletteFor(category),
        body: const [], // headline-only license: never render a body in-app
        publishedAt: publishedAt,
        provider: ArticleProvider.newsdata,
        hasFullText: false,
        sourceIconUrl: (item['source_icon'] as String?) ?? '',
      ),
      trusted: SourceQuality.isTrusted(domain),
      hasImage: imageUrl.isNotEmpty,
      sourcePriority: (item['source_priority'] as num?)?.toInt() ?? 1 << 30,
    );
  }

  /// A cover URL the image pipeline can actually decode: http(s) and not an
  /// SVG (Flutter has no SVG codec, so those covers would silently fail and
  /// still outrank genuinely imageless stories).
  static String _validImageUrl(String? url) {
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return '';
    }
    return uri.path.toLowerCase().endsWith('.svg') ? '' : url!;
  }
}

/// An article plus the quality signals used to order the NewsData pool.
class _Ranked {
  const _Ranked(
    this.article, {
    required this.trusted,
    required this.hasImage,
    required this.sourcePriority,
  });

  final Article article;
  final bool trusted;
  final bool hasImage;
  final int sourcePriority;
}
