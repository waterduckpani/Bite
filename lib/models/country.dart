/// The user's country, a plain onboarding/profile preference used to lightly
/// weight country-relevant coverage in the feed. NO location permission or
/// geolocation is involved — it's a manual selection.
///
/// [global] means "no country nudge". The enum [name] is what persists to
/// profiles.country; the server matches it against the publisher's own section
/// labels and the article URL's path for the mild feed weighting
/// (get_personalized_feed). This is not a Local mode.
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
