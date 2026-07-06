import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../models/article.dart';
import 'guardian_api.dart';
import 'newsdata_api.dart';

/// Fetches and merges live content from every configured source.
///
/// Results are cached in memory with a TTL that keeps us far inside each
/// API's free-tier budget (Guardian: 500 calls/day; NewsData: 200
/// credits/day) no matter how often the app asks for content.
class ContentService {
  ContentService({GuardianApi? guardian, NewsdataApi? newsdata})
      : _guardian = guardian ??
            (AppConfig.guardianApiKey != null
                ? GuardianApi(AppConfig.guardianApiKey!)
                : null),
        _newsdata = newsdata ??
            (AppConfig.newsdataApiKey != null
                ? NewsdataApi(AppConfig.newsdataApiKey!)
                : null);

  final GuardianApi? _guardian;
  final NewsdataApi? _newsdata;

  static const _ttl = Duration(minutes: 15);
  static List<Article>? _cache;
  static DateTime? _fetchedAt;

  /// Live articles, newest first, deduplicated across outlets. Returns an
  /// empty list when no source is configured or every source failed —
  /// callers fall back to mock data.
  Future<List<Article>> fetch({bool force = false}) async {
    final cache = _cache;
    if (!force &&
        cache != null &&
        _fetchedAt != null &&
        DateTime.now().difference(_fetchedAt!) < _ttl) {
      return cache;
    }

    final results = await Future.wait([
      _guarded('Guardian', _guardian?.fetchLatest()),
      _guarded('NewsData', _newsdata?.fetchLatest()),
    ]);
    final guardian = [...results[0]]..sort((a, b) {
        final at = a.publishedAt, bt = b.publishedAt;
        if (at == null || bt == null) return 0;
        return bt.compareTo(at);
      });
    final newsdata = results[1]; // already in quality order
    if (guardian.isEmpty && newsdata.isEmpty) return const [];

    // Interleave rather than date-sort: the Guardian publishes continuously,
    // so a pure recency sort buries every other outlet under a wall of
    // Guardian stories. Each source keeps its own order (Guardian newest
    // first, NewsData best first) and the deck mixes them evenly.
    final merged = _interleave(guardian, _dedupe(guardian, newsdata));
    debugPrint('ContentService: ${guardian.length} Guardian + '
        '${merged.length - guardian.length} NewsData after quality filters');

    _cache = merged;
    _fetchedAt = DateTime.now();
    return merged;
  }

  /// Merges two ordered lists so each is spread evenly across the result —
  /// at any point in the deck the ratio of sources matches their overall
  /// ratio, so neither outlet dominates a stretch.
  static List<Article> _interleave(List<Article> a, List<Article> b) {
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    final merged = <Article>[];
    var ai = 0, bi = 0;
    while (ai < a.length && bi < b.length) {
      // Take from whichever list is further behind its proportional pace.
      final aPace = (ai + 0.5) / a.length;
      final bPace = (bi + 0.5) / b.length;
      merged.add(aPace <= bPace ? a[ai++] : b[bi++]);
    }
    return merged
      ..addAll(a.sublist(ai))
      ..addAll(b.sublist(bi));
  }

  static Future<List<Article>> _guarded(
      String name, Future<List<Article>>? call) async {
    if (call == null) return const [];
    try {
      return await call;
    } catch (e) {
      debugPrint('ContentService: $name fetch failed: $e');
      return const [];
    }
  }

  /// Same story covered by several outlets: keep one copy, preferring the
  /// Guardian version because it carries licensed full text. Returns the
  /// [secondary] articles that don't duplicate [preferred] (or each other).
  static List<Article> _dedupe(
      List<Article> preferred, List<Article> secondary) {
    final kept = <Article>[];
    final seenTitles = [for (final a in preferred) _titleTokens(a.headline)];
    for (final candidate in secondary) {
      final tokens = _titleTokens(candidate.headline);
      final isDup = seenTitles.any((s) => _jaccard(s, tokens) >= 0.5);
      if (!isDup) {
        kept.add(candidate);
        seenTitles.add(tokens);
      }
    }
    return kept;
  }

  static const _stopwords = {
    'a', 'an', 'and', 'as', 'at', 'be', 'by', 'for', 'from', 'in', 'is',
    'it', 'of', 'on', 'the', 'to', 'with', 'after', 'over', 'says', 'say',
  };

  static Set<String> _titleTokens(String title) => title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.length > 1 && !_stopwords.contains(w))
      .toSet();

  static double _jaccard(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final intersection = a.intersection(b).length;
    return intersection / (a.length + b.length - intersection);
  }
}
