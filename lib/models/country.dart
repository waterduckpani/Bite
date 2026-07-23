/// The user's country, a plain onboarding/profile preference used to lightly
/// weight country-relevant Guardian coverage in the feed. NO location
/// permission or geolocation is involved — it's a manual selection.
///
/// [global] means "no country nudge". The enum [name] is what persists to
/// profiles.country; the server maps it to a Guardian tag segment for the
/// mild feed weighting (get_personalized_feed). Groundwork for Phase 12 — this
/// is not a Local mode.
enum Country {
  global('Global'),
  us('United States'),
  uk('United Kingdom'),
  india('India'),
  australia('Australia'),
  canada('Canada');

  const Country(this.label);
  final String label;

  static Country fromName(String? name) =>
      Country.values.asNameMap()[name] ?? Country.global;
}
