import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/palettes.dart';
import '../models/article.dart';

/// Guardian Open Platform client. The developer tier licenses full article
/// text, so these stories render in the native reader.
class GuardianApi {
  GuardianApi(this.apiKey, {http.Client? client})
      : _client = client ?? http.Client();

  final String apiKey;
  final http.Client _client;

  static const _host = 'content.guardianapis.com';

  /// Sections we ingest, mapped onto Bite's categories.
  static const _sectionToCategory = <String, Category>{
    'technology': Category.tech,
    'world': Category.world,
    'business': Category.business,
    'sport': Category.sports,
    'science': Category.science,
    'culture': Category.entertainment,
    'film': Category.entertainment,
    'music': Category.entertainment,
    'tv-and-radio': Category.entertainment,
    'books': Category.entertainment,
    'games': Category.entertainment,
  };

  Future<List<Article>> fetchLatest({int pageSize = 30}) async {
    final uri = Uri.https(_host, '/search', {
      'api-key': apiKey,
      'section': _sectionToCategory.keys.join('|'),
      'show-fields': 'trailText,byline,body,thumbnail,wordcount',
      'page-size': '$pageSize',
      'order-by': 'newest',
    });

    final res =
        await _client.get(uri).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) {
      throw http.ClientException('Guardian HTTP ${res.statusCode}', uri);
    }
    final response =
        (jsonDecode(res.body) as Map<String, dynamic>)['response']
            as Map<String, dynamic>;
    if (response['status'] != 'ok') {
      throw http.ClientException('Guardian status ${response['status']}', uri);
    }

    final results = (response['results'] as List).cast<Map<String, dynamic>>();
    return [
      for (final item in results)
        if (_map(item) case final article?) article,
    ];
  }

  Article? _map(Map<String, dynamic> item) {
    final category = _sectionToCategory[item['sectionId']];
    if (category == null) return null;

    final fields = (item['fields'] as Map<String, dynamic>?) ?? const {};
    final body = _paragraphs(fields['body'] as String? ?? '');
    if (body.isEmpty) return null; // liveblogs/galleries: skip

    final wordcount = int.tryParse('${fields['wordcount'] ?? ''}') ?? 0;
    final byline = (fields['byline'] as String?)?.trim();

    return Article(
      id: 'guardian:${item['id']}',
      headline: item['webTitle'] as String? ?? '',
      source: 'The Guardian',
      author: (byline == null || byline.isEmpty) ? 'The Guardian' : byline,
      category: category,
      imageUrl: fields['thumbnail'] as String? ?? '',
      snippet: _plainText(fields['trailText'] as String? ?? ''),
      url: item['webUrl'] as String? ?? '',
      readMinutes: (wordcount / 220).ceil().clamp(1, 30),
      palette: paletteFor(category),
      body: body,
      publishedAt:
          DateTime.tryParse(item['webPublicationDate'] as String? ?? ''),
      provider: ArticleProvider.guardian,
      hasFullText: true,
    );
  }

  /// Extracts readable paragraphs from the Guardian's HTML body.
  static List<String> _paragraphs(String html) {
    final matches = RegExp(r'<p>(.*?)</p>', dotAll: true).allMatches(html);
    return [
      for (final m in matches)
        if (_plainText(m.group(1)!) case final text when text.length > 1) text,
    ];
  }

  static String _plainText(String html) => html
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&nbsp;', ' ')
      .trim();
}
