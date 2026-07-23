import 'package:flutter/material.dart';

import '../models/article.dart';
import '../models/story_tracker.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/pressable.dart';
import '../widgets/reader_cue.dart';
import 'reader_screen.dart';

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
                            'Following since ${_date(tracker.createdAt)}'
                            '${tracker.muted ? '  ·  Muted' : ''}',
                            style: sans(size: 12, color: bite.muted),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
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

  String _date(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[dt.month - 1]} ${dt.day}';
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
      onTap: () => ReaderScreen.open(context, article),
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
                style: sans(size: 13.5, height: 1.5, color: bite.muted),
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
