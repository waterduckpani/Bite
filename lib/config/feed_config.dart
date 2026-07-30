/// Client-side Phase 11 feed constants. The recommendation/ranking weights
/// (W_READ, W_SAVE, EXPLORE_RATIO, blend weights…) live server-side in the
/// get_personalized_feed migrations — the client never ranks. What lives here
/// is only what the client itself needs to gate UI.
abstract final class FeedConfig {
  /// Bump to re-run the walkthrough after a gesture-mapping change.
  /// Persisted per user as `profiles.gesture_tutorial_version`; the
  /// walkthrough runs whenever the stored version is below this.
  /// (Spec: TUTORIAL_VERSION.)
  ///
  /// 2 = Phase 17. Version 1 was the static four-row coach-mark; this is the
  /// interactive walkthrough, and it teaches an action (following a story)
  /// the old overlay never mentioned. Everyone who saw version 1 sees this
  /// once, which is the point of versioning it.
  static const int gestureTutorialVersion = 2;

  /// Newest articles kept per tracker. A tracker is a window onto a developing
  /// story, not an archive — older entries fall off as fresh coverage arrives.
  /// MUST match TRACKER_MAX_ARTICLES in match-trackers and the LIMIT in
  /// get_tracker_articles; this copy exists only so the UI can say so.
  static const int trackerMaxArticles = 15;

  /// Signal weights and blend used by get_personalized_feed (migration 0009).
  ///
  /// The client still never ranks — these are copies kept ONLY so the Profile
  /// screen can show a reader what the recommender actually does with their
  /// swipes, in the recommender's own numbers. If the migration's constants
  /// change, change these with them; a Profile screen that describes a ranking
  /// the server no longer runs is worse than no Profile screen.
  static const double wRead = 1.0;
  static const double wSave = 1.3;
  static const double wOpen = 0.6;

  /// Blend: taste similarity, topic match, recency, and the reject centroid.
  static const double wSimilarity = 0.55;
  static const double wTopic = 0.25;
  static const double wRecency = 0.25;
  static const double wAvoid = 0.15;

  /// Recency half-life in hours, and how far back the candidate pool reaches.
  static const int recencyHalfLifeHours = 36;
  static const int poolHours = 48;

  /// How many recent swipes build the taste vector, and the minimum positive
  /// signals before personalisation kicks in at all (below it the feed is
  /// ranked on topics + recency only).
  static const int swipeWindow = 50;
  static const int coldStartMin = 5;

  /// A tracker with no new development for this many days is treated as stale
  /// and the user is offered a way out of it.
  ///
  /// Deliberately a SUGGESTION, never automatic: a story can go quiet for a
  /// fortnight and then break again, so Bite prompts rather than unfollowing
  /// on the user's behalf. Seven days is long enough that an ordinary weekend
  /// lull doesn't trigger it.
  static const int trackerStaleDays = 7;
}
