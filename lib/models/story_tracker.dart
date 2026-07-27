import '../config/feed_config.dart';

/// A followed story: a user-created tracker that collects new articles the
/// server matches to it (Phase 13). Trackers live in their own Tracked
/// section and never touch the main swipe feed's ranking.
///
/// This is the list-row view of a tracker — the timeline of matched articles
/// is fetched on demand for the detail screen. Counts (article/unread) and the
/// latest development come from the get_trackers RPC; a freshly-followed
/// tracker is built locally with just its seed until the next refresh.
class StoryTracker {
  const StoryTracker({
    required this.id,
    required this.title,
    required this.seedArticleId,
    required this.createdAt,
    this.muted = false,
    this.articleCount = 1,
    this.unreadCount = 0,
    this.latestTitle,
    this.latestAt,
  });

  final String id;
  final String title;

  /// The article the tracker was seeded from. Null only if that article was
  /// later purged from the pool (the tracker itself survives).
  final String? seedArticleId;

  final DateTime createdAt;

  /// Muted trackers keep their history but stop matching new articles.
  final bool muted;

  /// Total matched articles, including the seed.
  final int articleCount;

  /// Unseen matched articles — drives the per-tracker and tab unread badges.
  final int unreadCount;

  /// Headline + time of the most recent development, for the list row.
  final String? latestTitle;
  final DateTime? latestAt;

  /// Activity time used to sort the list (most recent development, or the
  /// creation time for a tracker with no new developments yet).
  DateTime get activityAt => latestAt ?? createdAt;

  /// How long this story has been quiet.
  Duration get sinceActivity => DateTime.now().difference(activityAt);

  /// Whole days since the last development — what the stale prompt shows.
  int get daysQuiet => sinceActivity.inDays;

  /// Whether the story has gone quiet long enough to suggest unfollowing.
  ///
  /// Muted trackers are never stale: the user already told us to stop watching
  /// this one, so nagging them about it would be noise. A tracker that has
  /// never matched anything DOES go stale off its creation time — "you
  /// followed this a week ago and nothing came of it" is exactly the case
  /// worth surfacing.
  bool get isStale =>
      !muted && daysQuiet >= FeedConfig.trackerStaleDays;

  StoryTracker copyWith({
    String? title,
    bool? muted,
    int? articleCount,
    int? unreadCount,
    String? latestTitle,
    DateTime? latestAt,
  }) =>
      StoryTracker(
        id: id,
        title: title ?? this.title,
        seedArticleId: seedArticleId,
        createdAt: createdAt,
        muted: muted ?? this.muted,
        articleCount: articleCount ?? this.articleCount,
        unreadCount: unreadCount ?? this.unreadCount,
        latestTitle: latestTitle ?? this.latestTitle,
        latestAt: latestAt ?? this.latestAt,
      );

  static StoryTracker? fromRow(Map<String, dynamic> row) {
    final id = row['id'] as String?;
    if (id == null) return null;
    return StoryTracker(
      id: id,
      title: row['title'] as String? ?? 'Followed story',
      seedArticleId: row['seed_article_id'] as String?,
      createdAt:
          DateTime.tryParse(row['created_at'] as String? ?? '')?.toLocal() ??
              DateTime.now(),
      muted: row['muted'] as bool? ?? false,
      articleCount: (row['article_count'] as num?)?.toInt() ?? 0,
      unreadCount: (row['unread_count'] as num?)?.toInt() ?? 0,
      latestTitle: row['latest_title'] as String?,
      latestAt:
          DateTime.tryParse(row['latest_at'] as String? ?? '')?.toLocal(),
    );
  }
}
