/// Client-side Phase 11 feed constants. The recommendation/ranking weights
/// (W_READ, W_SAVE, EXPLORE_RATIO, blend weights…) live server-side in the
/// get_personalized_feed migrations — the client never ranks. What lives here
/// is only what the client itself needs to gate UI.
abstract final class FeedConfig {
  /// Bump to re-show the gesture tutorial after a gesture-mapping change.
  /// Persisted per user as `profiles.gesture_tutorial_version`; the overlay
  /// shows whenever the stored version is below this. (Spec: TUTORIAL_VERSION.)
  static const int gestureTutorialVersion = 1;

  /// Newest articles kept per tracker. A tracker is a window onto a developing
  /// story, not an archive — older entries fall off as fresh coverage arrives.
  /// MUST match TRACKER_MAX_ARTICLES in match-trackers and the LIMIT in
  /// get_tracker_articles; this copy exists only so the UI can say so.
  static const int trackerMaxArticles = 15;

  /// A tracker with no new development for this many days is treated as stale
  /// and the user is offered a way out of it.
  ///
  /// Deliberately a SUGGESTION, never automatic: a story can go quiet for a
  /// fortnight and then break again, so Bite prompts rather than unfollowing
  /// on the user's behalf. Seven days is long enough that an ordinary weekend
  /// lull doesn't trigger it.
  static const int trackerStaleDays = 7;
}
