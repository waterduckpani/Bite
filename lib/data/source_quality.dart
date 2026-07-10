/// Source-domain helpers.
///
/// The curated source-quality lists (trusted/blocked domains, request-time
/// excludes) moved server-side in Phase 8 along with news ingestion — the
/// one place to edit when tuning the feed is now
/// `supabase/functions/ingest-news/index.ts`.
abstract final class SourceQuality {
  /// The source domain of [url], normalized for matching ("www." stripped).
  static String domainOf(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.startsWith('www.') ? host.substring(4) : host;
  }
}
