/// The user's region — a plain onboarding/profile preference that applies a
/// mild ADDITIVE boost to publishers tagged for that region. NO location
/// permission or geolocation is involved; it's a manual selection.
///
/// Phase 16 replaced the Phase 12 `Country` enum and, with it, the whole way
/// the preference was measured. The old nudge scored an article by looking for
/// country words in its URL slug and its RSS category strings — which measured
/// slug style, not relevance, and quietly scored nothing at all for the three
/// publishers that expose no categories (see migration 0019). The boost now
/// reads `publishers.region`: "this is an Indian outlet" is a fact on the
/// registry row; "this URL contains india" was an accident.
///
/// [tag] is what persists to `profiles.region` and what the server compares
/// against `publishers.region`, so the two vocabularies are literally the same
/// strings. [Region.global] applies no boost — a deliberately balanced pool.
///
/// This is a BOOST, never a filter: global and out-of-region stories always
/// still flow, and no selection can ever produce a region-only feed.
enum Region {
  global('Global', 'GLOBAL'),
  us('United States', 'US'),
  uk('United Kingdom', 'UK'),
  eu('Europe', 'EU'),
  india('India', 'IN'),
  australia('Australia', 'AU');

  const Region(this.label, this.tag);

  /// Display name in the region selector.
  final String label;

  /// The registry vocabulary: what is stored in `profiles.region` and matched
  /// against `publishers.region`.
  final String tag;

  /// Reads a stored [tag] back. Unknown values (including the Phase 12
  /// `country` names, and `canada` which Phase 16 dropped) fall back to
  /// [Region.global] — no boost, which is the safe default.
  static Region fromTag(String? tag) {
    if (tag == null) return Region.global;
    for (final r in Region.values) {
      if (r.tag == tag) return r;
    }
    return Region.global;
  }
}
