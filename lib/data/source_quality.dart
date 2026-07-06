/// Curated source-quality lists applied to NewsData.io results.
///
/// This is the one file to edit when tuning the feed:
///  - [trustedDomains] float to the top of the deck,
///  - [blockedDomains] never reach the feed,
///  - [excludeOnRequest] (the five worst offenders) are also filtered
///    server-side so they don't waste result slots.
///
/// Domains are matched against the story's source domain with any leading
/// "www." removed; subdomains of a listed domain match too.
abstract final class SourceQuality {
  /// Reputable outlets given priority placement in the deck.
  static const trustedDomains = <String>{
    // Wires & broadcasters
    'apnews.com', 'reuters.com', 'bbc.com', 'bbc.co.uk', 'npr.org',
    'aljazeera.com', 'cnn.com', 'nbcnews.com', 'cbsnews.com',
    'abcnews.go.com', 'theguardian.com',
    // Papers & magazines
    'nytimes.com', 'washingtonpost.com', 'wsj.com', 'latimes.com',
    'usatoday.com', 'independent.co.uk', 'telegraph.co.uk', 'time.com',
    'theatlantic.com', 'economist.com', 'newyorker.com',
    // Business
    'bloomberg.com', 'cnbc.com', 'ft.com', 'axios.com', 'politico.com',
    'fortune.com', 'businessinsider.com',
    // Tech
    'theverge.com', 'arstechnica.com', 'wired.com', 'techcrunch.com',
    'engadget.com', 'zdnet.com', 'macrumors.com', '9to5mac.com',
    // Sport
    'espn.com', 'skysports.com', 'theathletic.com', 'bleacherreport.com',
    // Science
    'nature.com', 'scientificamerican.com', 'newscientist.com',
    'sciencedaily.com', 'space.com', 'nationalgeographic.com',
    'phys.org', 'livescience.com',
    // Culture
    'variety.com', 'hollywoodreporter.com', 'rollingstone.com',
    'billboard.com', 'deadline.com', 'pitchfork.com',
  };

  /// Junk that must never reach the feed: press-release wires, scraper
  /// aggregators and SEO content farms.
  static const blockedDomains = <String>{
    // Press-release wires
    'prnewswire.com', 'businesswire.com', 'globenewswire.com',
    'einpresswire.com', 'einnews.com', 'openpr.com', 'newswire.com',
    'accesswire.com', 'issuewire.com', 'prlog.org',
    // Scraper aggregators & content farms
    'menafn.com', 'biztoc.com', 'headtopics.com', 'wn.com',
    'newsbreak.com', 'knewz.com', 'onenewspage.com', 'devdiscourse.com',
    'bignewsnetwork.com', 'streetinsider.com',
  };

  /// The five worst offenders, passed as `excludedomain` on every NewsData
  /// request so their stories never spend result slots.
  static const excludeOnRequest = <String>[
    'menafn.com',
    'prnewswire.com',
    'globenewswire.com',
    'businesswire.com',
    'einpresswire.com',
  ];

  static bool isTrusted(String domain) => _matches(trustedDomains, domain);

  static bool isBlocked(String domain) => _matches(blockedDomains, domain);

  /// The source domain of [url], normalized for matching ("www." stripped).
  static String domainOf(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  static bool _matches(Set<String> domains, String domain) =>
      domains.any((d) => domain == d || domain.endsWith('.$d'));
}
