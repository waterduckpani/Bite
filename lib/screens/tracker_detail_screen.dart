import 'package:flutter/material.dart';

import '../models/article.dart';
import '../models/story_tracker.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/pressable.dart';
import '../widgets/reader_cue.dart';
import 'browser_screen.dart';
import 'tracked_screen.dart' show TrackerStatsRow;

/// A tracker's developing story, newest development first. This is a timeline,
/// NOT a personalised feed — no taste ranking, straight reverse-chronological
/// order. Opening it marks the tracker's new articles as seen.
class TrackerDetailScreen extends StatefulWidget {
  const TrackerDetailScreen({super.key, required this.tracker});

  final StoryTracker tracker;

  @override
  State<TrackerDetailScreen> createState() => _TrackerDetailScreenState();
}

class _TrackerDetailScreenState extends State<TrackerDetailScreen> {
  Future<List<Article>>? _articles;

  StoryTracker get tracker => widget.tracker;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_articles == null) {
      final state = AppScope.of(context);
      // Clear the unread badge on view.
      state.markTrackerViewed(tracker.id);
      _articles = state.trackerArticles(tracker.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Scaffold(
      backgroundColor: bite.paper,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back, color: bite.ink),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tracker.title,
                            style: display(size: 24, weight: 620, height: 1.15),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _originLine(tracker),
                            style: sans(size: 12, color: bite.muted),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // The same toggle the reader has: whatever turned following
                  // on turns it off, wherever the reader happens to be.
                  IconButton(
                    tooltip: 'Stop following',
                    icon: Icon(Icons.notifications_active, color: bite.accent),
                    onPressed: () => _confirmUnfollow(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: TrackerStatsRow(tracker: tracker),
            ),
            // A story that has stopped developing. Offered as a suggestion,
            // never acted on automatically — a thread can go quiet for a week
            // and then break again, so the decision stays with the reader.
            if (tracker.isStale)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: _StalePrompt(
                  tracker: tracker,
                  onUnfollow: () => _confirmUnfollow(context),
                ),
              ),
            const SizedBox(height: 12),
            Expanded(
              child: FutureBuilder<List<Article>>(
                future: _articles,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                    );
                  }
                  final articles = snap.data ?? const <Article>[];
                  if (articles.isEmpty) return const _EmptyTimeline();
                  return _Timeline(articles: articles);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Unfollowing is destructive (the timeline goes with it), so it stays
  /// behind a confirm here exactly as it does in tracker management — a stale
  /// prompt must not become a one-tap way to lose history.
  Future<void> _confirmUnfollow(BuildContext context) async {
    final state = AppScope.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Stop following?'),
        content: Text(
          '“${tracker.title}” and its timeline will be removed. '
          'Saved stories and your reading history are unaffected.',
          style: sans(size: 13.5, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep following'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Unfollow'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    state.deleteTracker(tracker.id);
    Navigator.of(context).pop();
  }

  /// Where the story came from and when the reader picked it up — the two
  /// facts a timeline can't show for itself.
  String _originLine(StoryTracker t) {
    final parts = <String>[
      if (t.seedSource != null && t.seedSource!.isNotEmpty)
        'From ${t.seedSource}',
      'following since ${_date(t.createdAt)}',
      if (t.muted) 'muted',
    ];
    final line = parts.join('  ·  ');
    return line[0].toUpperCase() + line.substring(1);
  }

  String _date(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[dt.month - 1]} ${dt.day}';
  }
}

/// Shown when a followed story has gone quiet for [FeedConfig.trackerStaleDays].
///
/// Deliberately low-key: a muted card, not an alert. The story may simply be
/// between developments, so this offers an exit rather than declaring the
/// story over. Muting is offered alongside unfollowing because it keeps the
/// history while stopping the matching.
class _StalePrompt extends StatelessWidget {
  const _StalePrompt({required this.tracker, required this.onUnfollow});

  final StoryTracker tracker;
  final VoidCallback onUnfollow;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    final state = AppScope.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: bite.ink.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: bite.border, width: 0.75),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.history_toggle_off, size: 16, color: bite.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Quiet for ${tracker.daysQuiet} days',
                  style: sans(
                      size: 13, weight: FontWeight.w600, color: bite.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'No new coverage has matched this story in a while. It may have '
            'run its course — or it may pick up again.',
            style: sans(size: 12.5, height: 1.45, color: bite.muted),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () {
                  state.setTrackerMuted(tracker.id, true);
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(const SnackBar(
                      content: Text('Muted — history kept'),
                      duration: Duration(milliseconds: 1400),
                    ));
                },
                child: Text('Mute',
                    style: sans(size: 13, color: bite.muted)),
              ),
              TextButton(
                onPressed: onUnfollow,
                child: Text('Unfollow',
                    style: sans(
                        size: 13,
                        weight: FontWeight.w600,
                        color: bite.accent)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.articles});

  final List<Article> articles;

  @override
  Widget build(BuildContext context) {
    final bottomPad = 24 + MediaQuery.paddingOf(context).bottom;
    // A single-article timeline is just the seed: say so plainly rather than
    // implying developments have arrived.
    final onlySeed = articles.length == 1;
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(20, 0, 20, bottomPad),
      itemCount: articles.length + (onlySeed ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, i) {
        if (onlySeed && i == 0) return const _NoDevelopmentsYet();
        final article = articles[onlySeed ? i - 1 : i];
        return _TimelineEntry(article: article);
      },
    );
  }
}

/// One development in the timeline: the Phase 10 bite (hook + summary) where
/// available, the source + time, and the same reader routing / cue as the feed.
class _TimelineEntry extends StatelessWidget {
  const _TimelineEntry({required this.article});

  final Article article;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    final hasSummary = article.hasSummary;
    final lead = hasSummary ? article.aiSummaryHook! : article.headline;
    final body = hasSummary ? article.aiSummary! : article.snippet;
    return Pressable(
      onTap: () => BrowserScreen.open(context, article),
      child: Container(
        decoration: BoxDecoration(
          color: bite.card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: bite.border, width: 0.75),
        ),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              lead,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: display(size: 18, weight: 580, height: 1.2),
            ),
            if (body.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                body,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style:
                    sans(size: 13.5, wght: 450, height: 1.5, color: bite.body),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${article.source}  ·  ${article.timeAgo}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: sans(size: 12, color: bite.faint),
                  ),
                ),
                const SizedBox(width: 8),
                ReaderCue(article: article),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NoDevelopmentsYet extends StatelessWidget {
  const _NoDevelopmentsYet();

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: bite.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: bite.accent.withValues(alpha: 0.18), width: 0.75),
      ),
      child: Row(
        children: [
          Icon(Icons.schedule, size: 18, color: bite.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'No new developments yet. New stories on this will appear here '
              'as they’re published.',
              style: sans(size: 13, height: 1.45, color: bite.muted),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyTimeline extends StatelessWidget {
  const _EmptyTimeline();

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schedule, size: 36, color: bite.faint),
            const SizedBox(height: 12),
            Text('No developments yet', style: display(size: 20, weight: 600)),
            const SizedBox(height: 6),
            Text(
              'We’ll add stories here as this one develops.',
              textAlign: TextAlign.center,
              style: sans(size: 13.5, color: bite.muted),
            ),
          ],
        ),
      ),
    );
  }
}
