/// Client-side Phase 11 feed constants. The recommendation/ranking weights
/// (W_READ, W_SAVE, EXPLORE_RATIO, blend weights…) live server-side in the
/// get_personalized_feed migrations — the client never ranks. What lives here
/// is only what the client itself needs to gate UI.
abstract final class FeedConfig {
  /// Bump to re-show the gesture tutorial after a gesture-mapping change.
  /// Persisted per user as `profiles.gesture_tutorial_version`; the overlay
  /// shows whenever the stored version is below this. (Spec: TUTORIAL_VERSION.)
  static const int gestureTutorialVersion = 1;
}
