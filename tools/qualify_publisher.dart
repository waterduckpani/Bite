// Bite · Phase 14 · Part 0: publisher qualification.
//
// A STANDALONE diagnostic script. It is deliberately NOT part of the app
// bundle and imports nothing from lib/ — it only needs dart:io, so it runs
// with `dart run tools/qualify_publisher.dart <domain> [...]` without pub.
//
// Purpose: never guess a publisher's technical setup. Before a publisher can
// be added to the `publishers` registry (migration 0013) this script must
// have been run against it and its report committed under docs/publishers/.
// That is both the practical guard (RSS shapes vary wildly) and the good-faith
// paper trail if a publisher ever asks what Bite does with their feed.
//
// What it reports, per domain:
//   1. Does an RSS/Atom feed exist, and at what URL?
//   2. Does robots.txt allow BiteNewsBot to fetch article paths? Crawl-delay?
//   3. Does the feed carry full content (content:encoded) or description only?
//   4. Does the feed expose categories/sections (needed for opinion filtering)?
//   5. Roughly how many items per day (volume estimate for cap planning)?
//
// It NEVER circumvents anything: one honest User-Agent, no retries with
// different headers, robots.txt respected for every fetch it makes including
// the feed itself. A 403/paywall/consent wall is recorded as a finding, not
// worked around.
//
// Usage:
//   dart run tools/qualify_publisher.dart thehindu.com scroll.in
//   dart run tools/qualify_publisher.dart --all          # the candidate slate
//   dart run tools/qualify_publisher.dart --json thehindu.com
//
// Reports are written to docs/publishers/<domain>.md unless --no-write.

import 'dart:convert';
import 'dart:io';

// ---------------------------------------------------------------------------
// Bot identity. MUST match USER_AGENT in supabase/functions/_shared/bot.ts —
// the honest, fixed identifier Bite sends everywhere. Never a browser string,
// never rotated. The +url must resolve to a real page describing the bot.
// ---------------------------------------------------------------------------

const String kBotUrl = 'https://waterduckpani.github.io/Bite/bot';
const String kUserAgent = 'BiteNewsBot/1.0 (+$kBotUrl)';
const String kBotName = 'BiteNewsBot';

/// Floor on politeness between requests to the same host, matching
/// MIN_CRAWL_DELAY_MS in the ingest config. A publisher's own Crawl-delay
/// wins when it is longer.
const int kMinCrawlDelayMs = 1000;

const Duration kTimeout = Duration(seconds: 20);

// ---------------------------------------------------------------------------
// Candidate slate (--all).
//
// Selection follows the Phase 14 Part A criteria: reputable outlets with real
// reporting desks, a DELIBERATE spread across the political spectrum (balance
// comes from a spread of perspectives, not from hunting for bias-free sources
// — those don't exist), both IN and GLOBAL so the feed isn't lopsided, and
// mid-tier / regional rather than the largest nationals.
//
// `lean` is recorded to make the spread auditable, not to filter anything at
// runtime. It is a rough placement in that outlet's own national context.
// ---------------------------------------------------------------------------

class Candidate {
  const Candidate(this.domain, this.name, this.region, this.lean, this.why,
      {this.feedHint});
  final String domain;
  final String name;
  final String region; // IN | GLOBAL
  final String lean;
  final String why;

  /// An explicitly known feed URL, tried before discovery. Needed for
  /// publishers whose feed lives on a separate host (DW, CSM) or at a path
  /// no convention would guess (The Conversation's `/articles.atom`).
  /// Discovery still runs if the hint doesn't parse — the hint is a shortcut,
  /// never an assumption we skip verifying.
  final String? feedHint;
}

const List<Candidate> kCandidates = [
  // -- India ---------------------------------------------------------------
  Candidate('thehindu.com', 'The Hindu', 'IN', 'left-of-centre',
      'Long-standing national daily with a large reporting desk and a published corrections policy.'),
  Candidate('indianexpress.com', 'The Indian Express', 'IN', 'centrist',
      'Investigative tradition; centrist positioning balances the slate.'),
  Candidate('deccanherald.com', 'Deccan Herald', 'IN', 'centrist',
      'Bengaluru regional daily — mid-tier by design, not a top-two national.'),
  Candidate('theprint.in', 'ThePrint', 'IN', 'centre-right',
      'Digital-native with named bylines; leans right of the Hindu/Scroll pair.'),
  Candidate('scroll.in', 'Scroll.in', 'IN', 'left',
      'Digital-native reporting and explanatory journalism.'),
  Candidate('swarajyamag.com', 'Swarajya', 'IN', 'right',
      'Explicitly right-of-centre; included so the Indian slate is not one-sided.'),
  Candidate('firstpost.com', 'Firstpost', 'IN', 'right-of-centre',
      'Right-of-centre national digital outlet with a staffed desk — the '
      'counterweight to the Hindu/Scroll pair.'),
  Candidate('newindianexpress.com', 'The New Indian Express', 'IN',
      'centre-right', 'Southern regional daily, editorially distinct from The Hindu.'),
  Candidate('tribuneindia.com', 'The Tribune', 'IN', 'centrist',
      'Chandigarh regional daily covering the north — regional spread, not a top-two national.'),
  Candidate('telegraphindia.com', 'The Telegraph India', 'IN', 'left',
      'Kolkata daily with an openly adversarial editorial line — widens the spread at the other end.'),
  Candidate('livemint.com', 'Mint', 'IN', 'centre-right',
      'Business daily; market-liberal framing balances the general-news picks.'),
  // -- Global --------------------------------------------------------------
  Candidate('aljazeera.com', 'Al Jazeera', 'GLOBAL', 'left-of-centre',
      'Global desk with heavy Global South coverage the Guardian under-serves.'),
  Candidate('dw.com', 'Deutsche Welle', 'GLOBAL', 'centrist',
      'German public broadcaster; European perspective, English service.',
      feedHint: 'https://rss.dw.com/rdf/rss-en-all'),
  Candidate('csmonitor.com', 'The Christian Science Monitor', 'GLOBAL',
      'centrist', 'Mid-tier US outlet with an explicit non-partisan brief.',
      feedHint: 'https://rss.csmonitor.com/feeds/all'),
  Candidate('reason.com', 'Reason', 'GLOBAL', 'libertarian-right',
      'Libertarian-right; deliberate counterweight to the centre-left global picks.'),
  Candidate('theconversation.com', 'The Conversation', 'GLOBAL', 'centre-left',
      'Academic-authored explainers under Creative Commons.',
      feedHint: 'https://theconversation.com/articles.atom'),
  Candidate('france24.com', 'France 24', 'GLOBAL', 'centrist',
      'French public broadcaster, English service; Francophone Africa coverage.'),
];

// ---------------------------------------------------------------------------
// robots.txt
// ---------------------------------------------------------------------------

class RobotsRule {
  const RobotsRule(this.allow, this.pattern);
  final bool allow;
  final String pattern;

  /// Match length used for the longest-match-wins tiebreak. Wildcards make a
  /// pattern less specific, so its literal prefix is what counts.
  int get specificity => pattern.replaceAll('*', '').replaceAll(r'$', '').length;

  /// Google/RFC 9309 style matching: `*` is any run of characters, a trailing
  /// `$` anchors the end. Everything else is a literal prefix match.
  bool matches(String path) {
    final anchored = pattern.endsWith(r'$');
    final body = anchored ? pattern.substring(0, pattern.length - 1) : pattern;
    final parts = body.split('*');
    var index = 0;
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part.isEmpty) continue;
      if (i == 0) {
        if (!path.startsWith(part)) return false;
        index = part.length;
      } else {
        final found = path.indexOf(part, index);
        if (found < 0) return false;
        index = found + part.length;
      }
    }
    if (anchored && !body.endsWith('*')) return index == path.length;
    return true;
  }
}

class Robots {
  Robots({
    required this.fetched,
    required this.statusCode,
    required this.rules,
    required this.crawlDelay,
    required this.groupUsed,
    required this.raw,
  });

  final bool fetched;
  final int statusCode;
  final List<RobotsRule> rules;
  final double? crawlDelay;

  /// Which User-agent group the rules came from: the bot's own name, `*`,
  /// or `none` when neither appears.
  final String groupUsed;
  final String raw;

  /// A missing or unreadable robots.txt means "no stated restrictions".
  /// A 5xx is treated as restrictive: we do not fetch what we cannot verify.
  static Robots unreachable(int status) => Robots(
        fetched: false,
        statusCode: status,
        rules: const [],
        crawlDelay: null,
        groupUsed: 'none',
        raw: '',
      );

  /// Whether the bot may fetch [path]. Longest matching rule wins; a tie
  /// resolves to allow, and no matching rule means allowed.
  bool allows(String path) {
    // A robots.txt we could not read at all (network error / 5xx) is treated
    // as a disallow: better to fall back to RSS descriptions than to fetch
    // against rules we never saw.
    if (!fetched && statusCode >= 500) return false;
    RobotsRule? best;
    for (final rule in rules) {
      if (!rule.matches(path)) continue;
      if (best == null ||
          rule.specificity > best.specificity ||
          (rule.specificity == best.specificity && rule.allow)) {
        best = rule;
      }
    }
    return best?.allow ?? true;
  }

  static Robots parse(String text, int status) {
    // Groups are keyed by the agents named in a consecutive run of
    // `User-agent:` lines. Later groups for the same agent append.
    final groups = <String, List<RobotsRule>>{};
    final delays = <String, double>{};
    var currentAgents = <String>[];
    var expectingAgents = false;

    for (final rawLine in const LineSplitter().convert(text)) {
      final line = rawLine.split('#').first.trim();
      if (line.isEmpty) continue;
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final field = line.substring(0, colon).trim().toLowerCase();
      final value = line.substring(colon + 1).trim();

      switch (field) {
        case 'user-agent':
          if (!expectingAgents) {
            currentAgents = [];
            expectingAgents = true;
          }
          currentAgents.add(value.toLowerCase());
          groups.putIfAbsent(value.toLowerCase(), () => []);
        case 'disallow':
        case 'allow':
          expectingAgents = false;
          if (currentAgents.isEmpty) break;
          // An empty Disallow means "allow everything" — no rule to record.
          if (field == 'disallow' && value.isEmpty) break;
          if (value.isEmpty) break;
          for (final agent in currentAgents) {
            groups[agent]!.add(RobotsRule(field == 'allow', value));
          }
        case 'crawl-delay':
          expectingAgents = false;
          final parsed = double.tryParse(value);
          if (parsed == null) break;
          for (final agent in currentAgents) {
            delays[agent] = parsed;
          }
        default:
          expectingAgents = false;
      }
    }

    // Most specific group wins: our own name, then the wildcard.
    final botKey = kBotName.toLowerCase();
    final key = groups.containsKey(botKey)
        ? botKey
        : (groups.containsKey('*') ? '*' : null);
    return Robots(
      fetched: true,
      statusCode: status,
      rules: key == null ? const [] : groups[key]!,
      crawlDelay: key == null ? null : delays[key],
      groupUsed: key ?? 'none',
      raw: text,
    );
  }
}

// ---------------------------------------------------------------------------
// Minimal RSS / Atom reading.
//
// Regex-based on purpose: this is a diagnostic that must survive malformed
// feeds without a dependency. It mirrors the parser in the ingest-rss Edge
// Function so the qualification result reflects what ingestion will actually
// see.
// ---------------------------------------------------------------------------

class FeedItem {
  FeedItem({
    required this.title,
    required this.link,
    required this.description,
    required this.contentEncoded,
    required this.categories,
    required this.pubDate,
  });

  final String title;
  final String link;
  final String description;
  final String contentEncoded;
  final List<String> categories;
  final DateTime? pubDate;

  bool get hasFullContent => contentEncoded.trim().length > 800;
}

class Feed {
  Feed(this.url, this.items, this.isAtom);
  final String url;
  final List<FeedItem> items;
  final bool isAtom;
}

String _stripTags(String html) => html
    .replaceAll(RegExp(r'<[^>]+>'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _decodeEntities(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&');

/// Inner text of the first `<tag>` in [xml], CDATA unwrapped and entities
/// decoded. Namespaced tags are matched by their local name.
String _tag(String xml, String tag) {
  final match = RegExp(
    '<(?:[a-zA-Z0-9-]+:)?$tag(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[a-zA-Z0-9-]+:)?$tag>',
    caseSensitive: false,
  ).firstMatch(xml);
  if (match == null) return '';
  var value = match.group(1) ?? '';
  final cdata = RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>').firstMatch(value);
  if (cdata != null) value = cdata.group(1) ?? '';
  return _decodeEntities(value).trim();
}

List<String> _tags(String xml, String tag) => RegExp(
      '<(?:[a-zA-Z0-9-]+:)?$tag(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[a-zA-Z0-9-]+:)?$tag>',
      caseSensitive: false,
    ).allMatches(xml).map((m) {
      var value = m.group(1) ?? '';
      final cdata = RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>').firstMatch(value);
      if (cdata != null) value = cdata.group(1) ?? '';
      return _decodeEntities(value).trim();
    }).where((s) => s.isNotEmpty).toList();

/// Atom links live in an attribute, not the element body.
String _atomLink(String xml) {
  for (final m in RegExp(r'<link\b([^>]*)/?>', caseSensitive: false)
      .allMatches(xml)) {
    final attrs = m.group(1) ?? '';
    final rel = RegExp(r'''rel\s*=\s*["']([^"']*)["']''', caseSensitive: false)
        .firstMatch(attrs)
        ?.group(1);
    if (rel != null && rel != 'alternate') continue;
    final href =
        RegExp(r'''href\s*=\s*["']([^"']*)["']''', caseSensitive: false)
            .firstMatch(attrs)
            ?.group(1);
    if (href != null && href.isNotEmpty) return _decodeEntities(href);
  }
  return '';
}

DateTime? _parseDate(String raw) {
  if (raw.isEmpty) return null;
  final iso = DateTime.tryParse(raw);
  if (iso != null) return iso.toUtc();
  // RFC 822/1123: "Mon, 21 Jul 2026 14:03:00 +0530"
  final m = RegExp(
    r'(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4}|GMT|UTC)?',
  ).firstMatch(raw);
  if (m == null) return null;
  const months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };
  final month = months[m.group(2)!.toLowerCase()];
  if (month == null) return null;
  var dt = DateTime.utc(
    int.parse(m.group(3)!),
    month,
    int.parse(m.group(1)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6) ?? '0'),
  );
  final zone = m.group(7);
  if (zone != null && (zone.startsWith('+') || zone.startsWith('-'))) {
    final sign = zone.startsWith('-') ? 1 : -1;
    dt = dt.add(Duration(
      hours: sign * int.parse(zone.substring(1, 3)),
      minutes: sign * int.parse(zone.substring(3, 5)),
    ));
  }
  return dt;
}

Feed? parseFeed(String url, String body) {
  final isAtom = RegExp(r'<feed\b', caseSensitive: false).hasMatch(body) &&
      !RegExp(r'<rss\b', caseSensitive: false).hasMatch(body);
  final blocks = RegExp(
    isAtom ? r'<entry\b[\s\S]*?</entry>' : r'<item\b[\s\S]*?</item>',
    caseSensitive: false,
  ).allMatches(body).map((m) => m.group(0)!).toList();
  if (blocks.isEmpty) return null;

  final items = <FeedItem>[];
  for (final block in blocks) {
    final link = isAtom ? _atomLink(block) : _tag(block, 'link');
    final description = _stripTags(isAtom
        ? (_tag(block, 'summary').isNotEmpty
            ? _tag(block, 'summary')
            : _tag(block, 'content'))
        : _tag(block, 'description'));
    final content = isAtom ? _tag(block, 'content') : _tag(block, 'encoded');
    final categories = isAtom
        ? RegExp(r'''<category[^>]*term\s*=\s*["']([^"']+)["']''',
                caseSensitive: false)
            .allMatches(block)
            .map((m) => _decodeEntities(m.group(1)!))
            .toList()
        : _tags(block, 'category');
    final dateRaw = isAtom
        ? (_tag(block, 'published').isNotEmpty
            ? _tag(block, 'published')
            : _tag(block, 'updated'))
        : (_tag(block, 'pubDate').isNotEmpty
            ? _tag(block, 'pubDate')
            : _tag(block, 'date'));
    items.add(FeedItem(
      title: _stripTags(_tag(block, 'title')),
      link: link,
      description: description,
      contentEncoded: content,
      categories: categories,
      pubDate: _parseDate(dateRaw),
    ));
  }
  return Feed(url, items, isAtom);
}

// ---------------------------------------------------------------------------
// HTTP — one honest identity, no retries with different headers.
// ---------------------------------------------------------------------------

class Fetched {
  const Fetched(this.status, this.body, this.finalUrl, this.error);
  final int status;
  final String body;
  final String finalUrl;
  final String? error;
  bool get ok => status >= 200 && status < 300;
}

final HttpClient _http = HttpClient()
  ..userAgent = kUserAgent
  ..connectionTimeout = kTimeout;

Future<Fetched> fetch(String url) async {
  try {
    final request = await _http.getUrl(Uri.parse(url)).timeout(kTimeout);
    request.followRedirects = true;
    request.maxRedirects = 5;
    // Identify honestly and ask for what we can actually read. No browser
    // impersonation: no sec-ch-*, no Referer games, no cookie replay.
    request.headers.set(HttpHeaders.acceptHeader,
        'application/rss+xml, application/atom+xml, application/xml, text/xml, text/html;q=0.8');
    request.headers.set(HttpHeaders.acceptLanguageHeader, 'en');
    final response = await request.close().timeout(kTimeout);
    final body = await response
        .transform(const Utf8Decoder(allowMalformed: true))
        .join()
        .timeout(kTimeout);
    return Fetched(
        response.statusCode, body, '${request.uri}', null);
  } catch (e) {
    return Fetched(0, '', url, '$e');
  }
}

/// Signals that a page was not honestly served to us. Any hit means the
/// article is description-only — we never retry it with different headers.
const Map<String, List<String>> kWallSignals = {
  'paywall': [
    'subscribe to continue', 'subscription required', 'to continue reading',
    'this article is for subscribers', 'premium article', 'paywall',
    'already a subscriber', 'unlock this article',
  ],
  'consent_wall': [
    'accept all cookies', 'manage your privacy', 'we value your privacy',
    'consent to the use of cookies', 'privacy preference cent',
  ],
  'bot_challenge': [
    'enable javascript and cookies to continue', 'checking your browser',
    'verify you are human', 'cf-browser-verification', 'ddos protection by',
    'access denied', 'attention required! | cloudflare',
  ],
};

String? detectWall(String html) {
  final lower = html.toLowerCase();
  for (final entry in kWallSignals.entries) {
    for (final signal in entry.value) {
      if (lower.contains(signal)) return '${entry.key}:$signal';
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Feed discovery
// ---------------------------------------------------------------------------

const List<String> kCommonFeedPaths = [
  '/feed', '/feed/', '/rss', '/rss/', '/rss.xml', '/feed.xml', '/atom.xml',
  '/index.xml', '/articles.atom', '/feeds/all', '/rss/all',
  '/feeds/all.rss.xml', '/rssfeeds/1221656.cms', '/?feed=rss2',
  '/news/feed', '/latest/feed', '/rss/feed', '/feeds/rss',
];

/// `<link rel="alternate" type="application/rss+xml" href="…">` on the
/// homepage — the publisher's own declaration, tried before path guessing.
List<String> declaredFeeds(String html, Uri base) {
  final out = <String>[];
  for (final m
      in RegExp(r'<link\b[^>]*>', caseSensitive: false).allMatches(html)) {
    final tag = m.group(0)!;
    if (!RegExp(r'rel\s*=\s*["\x27][^"\x27]*alternate', caseSensitive: false)
        .hasMatch(tag)) {
      continue;
    }
    if (!RegExp(r'type\s*=\s*["\x27]application/(rss|atom)\+xml',
            caseSensitive: false)
        .hasMatch(tag)) {
      continue;
    }
    final href =
        RegExp(r'''href\s*=\s*["']([^"']+)["']''', caseSensitive: false)
            .firstMatch(tag)
            ?.group(1);
    if (href == null || href.isEmpty) continue;
    out.add(base.resolve(_decodeEntities(href)).toString());
  }
  return out;
}

// ---------------------------------------------------------------------------
// Qualification
// ---------------------------------------------------------------------------

class Report {
  Report(this.domain, this.name, this.region, this.lean);

  final String domain;
  final String name;
  final String region;
  final String lean;

  String? feedUrl;
  bool feedRobotsAllowed = true;
  int itemCount = 0;
  int withContent = 0;
  int withDescription = 0;
  int withCategories = 0;
  int withDate = 0;
  double? itemsPerDay;
  Duration? span;
  List<String> sampleCategories = [];
  List<String> triedFeeds = [];

  String robotsGroup = 'none';
  int robotsStatus = 0;
  double? crawlDelay;
  bool articlePathsAllowed = false;

  /// False when the feed yielded no absolute article links to test, so the
  /// report can say "not checked" instead of implying a disallow.
  bool articlePathsChecked = false;
  List<String> articlePathChecks = [];

  String? bodyProbeUrl;
  int bodyProbeStatus = 0;
  String? bodyProbeWall;
  int bodyProbeChars = 0;

  final List<String> notes = [];

  /// Full text may only be fetched when robots.txt allows the article path
  /// AND an honest fetch actually returned readable content.
  bool get fullTextAllowed =>
      articlePathsAllowed && bodyProbeWall == null && bodyProbeChars > 1200;

  /// Description-only publishers are still perfectly usable — they get a
  /// thinner bite from the RSS description. The only hard fail is having no
  /// readable feed at all.
  bool get passes =>
      feedUrl != null &&
      feedRobotsAllowed &&
      itemCount >= 3 &&
      (withDescription > 0 || withContent > 0);

  String get mode => withContent >= (itemCount / 2)
      ? 'rss-full-content'
      : (fullTextAllowed ? 'body-fetch-allowed' : 'description-only');

  Map<String, dynamic> toJson() => {
        'domain': domain,
        'name': name,
        'region': region,
        'lean': lean,
        'passes': passes,
        'feed_url': feedUrl,
        'mode': mode,
        'full_text_allowed': fullTextAllowed,
        'robots_group': robotsGroup,
        'robots_status': robotsStatus,
        'crawl_delay_seconds': crawlDelay,
        'article_paths_allowed': articlePathsAllowed,
        'items_in_feed': itemCount,
        'items_with_content_encoded': withContent,
        'items_with_description': withDescription,
        'items_with_categories': withCategories,
        'items_per_day_estimate': itemsPerDay,
        'sample_categories': sampleCategories,
        'notes': notes,
      };
}

/// robots.txt per origin, fetched once. Feeds and articles can live on
/// different hosts, and each host's rules govern its own paths.
final Map<String, Robots> _robotsCache = {};

Future<Robots> _robotsFor(String origin) async {
  final cached = _robotsCache[origin];
  if (cached != null) return cached;
  final res = await fetch('$origin/robots.txt');
  final robots = res.ok
      ? Robots.parse(res.body, res.status)
      : Robots.unreachable(res.status);
  return _robotsCache[origin] = robots;
}

Future<Report> qualify(Candidate candidate) async {
  final report =
      Report(candidate.domain, candidate.name, candidate.region, candidate.lean);
  final origin = 'https://www.${candidate.domain}';

  // 1. robots.txt FIRST — it governs every fetch below, including the feed.
  var robots = await _robotsFor(origin);
  if (!robots.fetched) robots = await _robotsFor('https://${candidate.domain}');
  report.robotsStatus = robots.statusCode;
  report.robotsGroup = robots.groupUsed;
  report.crawlDelay = robots.crawlDelay;
  if (!robots.fetched) {
    report.notes.add(
        'robots.txt not readable (HTTP ${robots.statusCode}).'
        '${robots.statusCode >= 500 ? " Treated as DISALLOW — we do not fetch against rules we could not read." : " Treated as no stated restrictions."}');
  }

  // 2. Feed discovery: the publisher's own declaration first, then the
  //    conventional paths. robots.txt is honoured for each probe.
  //    A publisher may serve on the apex, on www, or host feeds on a separate
  //    subdomain entirely — so try the hint, then both origins.
  final apex = 'https://${candidate.domain}';
  final candidates = <String>[
    if (candidate.feedHint != null) candidate.feedHint!,
  ];
  for (final o in {origin, apex}) {
    final home = await fetch(o);
    if (home.ok) candidates.addAll(declaredFeeds(home.body, Uri.parse(o)));
  }
  for (final o in {origin, apex}) {
    candidates.addAll(kCommonFeedPaths.map((p) => '$o$p'));
  }

  final seen = <String>{};
  Feed? parsed;
  for (final url in candidates) {
    if (!seen.add(url)) continue;
    final uri = Uri.parse(url);
    // A feed hosted on a different host (rss.dw.com, feeds.feedburner.com) is
    // governed by THAT host's robots.txt, not the publisher's.
    final feedRobots = uri.host == Uri.parse(origin).host
        ? robots
        : await _robotsFor('${uri.scheme}://${uri.host}');
    if (!feedRobots.allows(uri.path)) {
      report.triedFeeds.add('$url — SKIPPED (robots.txt disallows ${uri.path})');
      continue;
    }
    await Future<void>.delayed(Duration(
        milliseconds: _delayMs(feedRobots.crawlDelay)));
    final res = await fetch(url);
    if (!res.ok) {
      report.triedFeeds.add('$url — HTTP ${res.status}');
      continue;
    }
    final feed = parseFeed(url, res.body);
    if (feed == null) {
      report.triedFeeds.add('$url — HTTP 200 but no items parsed');
      continue;
    }
    report.triedFeeds.add('$url — OK, ${feed.items.length} items');
    _analyseFeed(report, feed);
    parsed = feed;
    report.feedUrl = url;
    report.feedRobotsAllowed = true;
    break;
  }

  if (parsed == null) {
    report.notes.add('No usable RSS/Atom feed found.');
    return report;
  }

  // 3. Article-path permission + an honest single body probe. Only performed
  //    when robots.txt allows the path; a wall aborts and is recorded.
  final sampleLinks = parsed.items
      .map((i) => i.link)
      .where((l) => l.startsWith('http') && l.contains(candidate.domain))
      .toList();
  for (final link in sampleLinks.take(3)) {
    final uri = Uri.parse(link);
    final articleRobots = uri.host == Uri.parse(origin).host
        ? robots
        : await _robotsFor('${uri.scheme}://${uri.host}');
    final allowed = articleRobots.allows(uri.path);
    report.articlePathsChecked = true;
    report.articlePathChecks
        .add('${allowed ? "ALLOW" : "DISALLOW"}  ${uri.host}${uri.path}');
    if (allowed) report.articlePathsAllowed = true;
  }
  if (sampleLinks.isEmpty) {
    report.notes.add('Feed exposed no absolute article links to test.');
  }

  if (report.articlePathsAllowed && sampleLinks.isNotEmpty) {
    final probe = sampleLinks.firstWhere(
        (l) => robots.allows(Uri.parse(l).path),
        orElse: () => '');
    if (probe.isNotEmpty) {
      await Future<void>.delayed(
          Duration(milliseconds: _delayMs(robots.crawlDelay)));
      final res = await fetch(probe);
      report.bodyProbeUrl = probe;
      report.bodyProbeStatus = res.status;
      if (res.ok) {
        report.bodyProbeWall = detectWall(res.body);
        report.bodyProbeChars = _readableChars(res.body);
        if (report.bodyProbeWall != null) {
          report.notes.add(
              'Body probe hit a wall (${report.bodyProbeWall}) — ABORTED, not retried. '
              'This publisher is description-only unless that changes.');
        }
      } else {
        report.notes.add(
            'Body probe returned HTTP ${res.status} to our honest User-Agent — '
            'no retry attempted. Treat as description-only.');
      }
    }
  } else if (report.feedUrl != null) {
    report.notes.add(
        'robots.txt disallows article paths for $kBotName — description-only. No override exists.');
  }

  return report;
}

int _delayMs(double? crawlDelay) {
  final stated = ((crawlDelay ?? 0) * 1000).round();
  return stated > kMinCrawlDelayMs ? stated : kMinCrawlDelayMs;
}

void _analyseFeed(Report report, Feed feed) {
  report.itemCount = feed.items.length;
  final categories = <String>{};
  final dates = <DateTime>[];
  for (final item in feed.items) {
    if (item.hasFullContent) report.withContent++;
    if (item.description.length > 40) report.withDescription++;
    if (item.categories.isNotEmpty) report.withCategories++;
    categories.addAll(item.categories);
    if (item.pubDate != null) {
      report.withDate++;
      dates.add(item.pubDate!);
    }
  }
  report.sampleCategories = categories.take(12).toList()..sort();

  if (dates.length >= 2) {
    dates.sort();
    final span = dates.last.difference(dates.first);
    report.span = span;
    final hours = span.inMinutes / 60.0;
    // A feed window shorter than an hour says "high volume" but can't be
    // extrapolated honestly; report it as a floor instead of a wild number.
    if (hours >= 0.5) {
      report.itemsPerDay = (dates.length / hours) * 24;
    } else {
      report.notes.add(
          'Feed window is under 30 minutes (${span.inMinutes}m for ${dates.length} items) — '
          'very high volume; treat items/day as ">${(dates.length * 48)}" and cap hard with max_per_run.');
    }
  } else {
    report.notes.add('Too few parseable dates to estimate volume.');
  }
}

/// Rough count of readable article text in an HTML page — enough to tell a
/// real body apart from a consent shell.
int _readableChars(String html) {
  final withoutScripts = html
      .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ');
  final paragraphs = RegExp(r'<p\b[\s\S]*?</p>', caseSensitive: false)
      .allMatches(withoutScripts)
      .map((m) => _stripTags(m.group(0)!))
      .where((t) => t.length > 60)
      .join(' ');
  return paragraphs.length;
}

// ---------------------------------------------------------------------------
// Report rendering
// ---------------------------------------------------------------------------

String renderMarkdown(Report r, DateTime at) {
  final b = StringBuffer()
    ..writeln('# ${r.name} — publisher qualification')
    ..writeln()
    ..writeln('- **Domain:** `${r.domain}`')
    ..writeln('- **Region:** ${r.region}')
    ..writeln('- **Editorial lean (recorded for slate balance, not used at runtime):** ${r.lean}')
    ..writeln('- **Checked:** ${at.toUtc().toIso8601String()}')
    ..writeln('- **User-Agent used:** `$kUserAgent`')
    ..writeln('- **Verdict:** ${r.passes ? "**PASS**" : "**FAIL**"} — ingestion mode `${r.mode}`')
    ..writeln();

  b
    ..writeln('## 1. RSS feed')
    ..writeln()
    ..writeln(r.feedUrl == null
        ? 'No usable feed found.'
        : '`${r.feedUrl}` — ${r.itemCount} items parsed.')
    ..writeln()
    ..writeln('<details><summary>URLs probed</summary>')
    ..writeln();
  for (final t in r.triedFeeds) {
    b.writeln('- $t');
  }
  b
    ..writeln()
    ..writeln('</details>')
    ..writeln();

  b
    ..writeln('## 2. robots.txt')
    ..writeln()
    ..writeln('- HTTP ${r.robotsStatus}, rules read from the `${r.robotsGroup}` group')
    ..writeln('- Crawl-delay: ${r.crawlDelay == null ? "not stated (floor ${kMinCrawlDelayMs}ms applies)" : "${r.crawlDelay}s"}')
    ..writeln('- Article paths allowed for `$kBotName`: '
        '**${!r.articlePathsChecked ? "not checked (no article links in feed)" : (r.articlePathsAllowed ? "yes" : "no")}**')
    ..writeln();
  if (r.articlePathChecks.isNotEmpty) {
    b.writeln('```');
    for (final c in r.articlePathChecks) {
      b.writeln(c);
    }
    b
      ..writeln('```')
      ..writeln();
  }

  b
    ..writeln('## 3. Content depth')
    ..writeln()
    ..writeln('| Signal | Count / ${r.itemCount} |')
    ..writeln('| --- | --- |')
    ..writeln('| `content:encoded` with real body | ${r.withContent} |')
    ..writeln('| usable `description` | ${r.withDescription} |')
    ..writeln('| carries `<category>` | ${r.withCategories} |')
    ..writeln('| parseable date | ${r.withDate} |')
    ..writeln();
  if (r.bodyProbeUrl != null) {
    b
      ..writeln('Body probe (single honest fetch, never retried):')
      ..writeln()
      ..writeln('- URL: `${r.bodyProbeUrl}`')
      ..writeln('- HTTP ${r.bodyProbeStatus}')
      ..writeln('- Wall detected: ${r.bodyProbeWall ?? "none"}')
      ..writeln('- Readable paragraph characters: ${r.bodyProbeChars}')
      ..writeln();
  }
  b
    ..writeln('**`full_text_allowed` → ${r.fullTextAllowed}**')
    ..writeln();

  b
    ..writeln('## 4. Categories (opinion filtering)')
    ..writeln()
    ..writeln(r.sampleCategories.isEmpty
        ? 'Feed exposes no categories — opinion filtering for this publisher '
            'relies on URL-path rules alone.'
        : 'Exposed: ${r.sampleCategories.map((c) => "`$c`").join(", ")}')
    ..writeln();

  b
    ..writeln('## 5. Volume')
    ..writeln()
    ..writeln(r.itemsPerDay == null
        ? 'Not estimable from this snapshot.'
        : '~${r.itemsPerDay!.round()} items/day '
            '(${r.itemCount} items spanning ${r.span!.inHours}h ${r.span!.inMinutes % 60}m).')
    ..writeln();

  if (r.notes.isNotEmpty) {
    b
      ..writeln('## Notes')
      ..writeln();
    for (final n in r.notes) {
      b.writeln('- $n');
    }
    b.writeln();
  }

  b
    ..writeln('---')
    ..writeln()
    ..writeln('Generated by `tools/qualify_publisher.dart`. Re-run before '
        'changing this publisher\'s registry row.');
  return b.toString();
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  final jsonOut = args.contains('--json');
  final noWrite = args.contains('--no-write');
  final all = args.contains('--all');
  final domains = args.where((a) => !a.startsWith('--')).toList();

  final targets = <Candidate>[
    if (all) ...kCandidates,
    for (final d in domains)
      kCandidates.firstWhere(
        (c) => c.domain == d,
        orElse: () => Candidate(d, d, 'GLOBAL', 'unclassified', 'ad-hoc check'),
      ),
  ];
  if (targets.isEmpty) {
    stderr.writeln('usage: dart run tools/qualify_publisher.dart '
        '[--all] [--json] [--no-write] <domain> ...');
    exit(64);
  }

  final at = DateTime.now();
  final reports = <Report>[];
  for (final candidate in targets) {
    stderr.writeln('→ ${candidate.domain}');
    final report = await qualify(candidate);
    reports.add(report);
    stderr.writeln(
        '  ${report.passes ? "PASS" : "FAIL"}  mode=${report.mode}  '
        'feed=${report.feedUrl ?? "-"}  items/day=${report.itemsPerDay?.round() ?? "?"}');
    if (!noWrite) {
      final dir = Directory('docs/publishers');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File('docs/publishers/${candidate.domain}.md')
          .writeAsStringSync(renderMarkdown(report, at));
    }
  }

  if (jsonOut) {
    stdout.writeln(
        const JsonEncoder.withIndent('  ').convert([for (final r in reports) r.toJson()]));
  }
  _http.close(force: true);
}
