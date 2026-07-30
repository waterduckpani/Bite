import 'package:animations/animations.dart';
import 'package:flutter/material.dart';

import '../models/story_tracker.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../widgets/bite_tab_bar.dart';
import '../widgets/pressable.dart';
import 'tracker_detail_screen.dart';
import 'tracker_management_screen.dart';

/// The Tracked tab: a self-contained section for followed stories, separate
/// from the swipe feed. Lists trackers by most recent development, each opening
/// a reverse-chronological timeline of its matched articles.
class TrackedScreen extends StatefulWidget {
  const TrackedScreen({super.key});

  @override
  State<TrackedScreen> createState() => _TrackedScreenState();
}

class _TrackedScreenState extends State<TrackedScreen> {
  bool _refreshed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The tab subtree is rebuilt on each switch, so this re-queries counts +
    // latest developments every time the user opens Tracked. AppScope isn't
    // available in initState.
    if (!_refreshed) {
      _refreshed = true;
      AppScope.of(context).refreshTrackers();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final bite = context.bite;
    final trackers = state.trackers;
    final bottomPad =
        24 + kBiteTabBarReserved + MediaQuery.paddingOf(context).bottom;

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 20, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Tracked', style: display(size: 34, weight: 640)),
                      const SizedBox(height: 2),
                      Text(
                        _summaryLine(trackers),
                        style: sans(size: 13, color: bite.muted),
                      ),
                    ],
                  ),
                ),
                if (trackers.isNotEmpty)
                  IconButton(
                    tooltip: 'Manage trackers',
                    icon: Icon(Icons.tune, size: 22, color: bite.ink),
                    onPressed: () => Navigator.of(context, rootNavigator: true)
                        .push(articleRoute(const TrackerManagementScreen())),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: trackers.isEmpty
                ? const _EmptyTracked()
                : RefreshIndicator(
                    onRefresh: state.refreshTrackers,
                    color: bite.accent,
                    child: ListView.separated(
                      key: const PageStorageKey('tracked.list'),
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(24, 0, 24, bottomPad),
                      itemCount: trackers.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, i) =>
                          _TrackerRow(tracker: trackers[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Headline for the whole section: how many stories are being followed, and
/// how much has landed on them that the reader hasn't seen.
String _summaryLine(List<StoryTracker> trackers) {
  if (trackers.isEmpty) return 'Follow a story to watch it develop';
  final stories =
      '${trackers.length} ${trackers.length == 1 ? 'story' : 'stories'} followed';
  final developments = trackers.fold(0, (sum, t) => sum + t.articleCount);
  final unread = trackers.fold(0, (sum, t) => sum + t.unreadCount);
  if (unread > 0) return '$stories  ·  $unread new';
  if (developments > trackers.length) return '$stories  ·  $developments updates';
  return stories;
}

/// A tracker list row that opens its timeline with a container transform.
///
/// A followed story is a thread, so the row shows the thread's shape — how
/// many developments, across how many outlets, over how long — rather than
/// only its latest headline.
class _TrackerRow extends StatelessWidget {
  const _TrackerRow({required this.tracker});

  final StoryTracker tracker;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    final reduced = reducedMotion(context);
    return OpenContainer(
      tappable: false,
      transitionDuration:
          reduced ? const Duration(milliseconds: 60) : BiteMotion.gentle,
      transitionType: ContainerTransitionType.fade,
      closedElevation: 0,
      openElevation: 0,
      closedColor: bite.card,
      middleColor: bite.paper,
      openColor: bite.paper,
      closedShape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      openBuilder: (context, _) => TrackerDetailScreen(tracker: tracker),
      closedBuilder: (context, openContainer) => Pressable(
        onTap: openContainer,
        child: Container(
          decoration: BoxDecoration(
            color: bite.card,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              // An unread tracker owns its edge — the badge alone was easy to
              // miss in a list of otherwise identical cards.
              color: tracker.unreadCount > 0
                  ? bite.accent.withValues(alpha: 0.45)
                  : bite.border,
              width: tracker.unreadCount > 0 ? 1 : 0.75,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(18, 16, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (tracker.muted) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Icon(Icons.notifications_off,
                          size: 15, color: bite.faint),
                    ),
                    const SizedBox(width: 6),
                  ]
                  // A story that has gone quiet gets a marker here and a full
                  // prompt inside. Marker only — Bite suggests unfollowing, it
                  // never does it for you.
                  else if (tracker.isStale) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Icon(Icons.history_toggle_off,
                          size: 15, color: bite.faint),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      tracker.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: display(size: 18, weight: 600, height: 1.15),
                    ),
                  ),
                  if (tracker.unreadCount > 0) ...[
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: bite.accent,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${tracker.unreadCount} new',
                        style: caps(size: 9, color: bite.onAccent),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              TrackerStatsRow(tracker: tracker),
              const SizedBox(height: 12),
              Divider(height: 1, thickness: 0.75, color: bite.border),
              const SizedBox(height: 12),
              _LatestDevelopment(tracker: tracker),
            ],
          ),
        ),
      ),
    );
  }
}

/// The stat strip shared by the Tracked list row and the timeline header:
/// developments, outlets, and how long the thread has been running.
///
/// Falls back to the old count-and-time line when the server hasn't been
/// migrated to the richer get_trackers yet ([StoryTracker.hasStats]) — an
/// honest smaller line beats a row of confident zeroes.
class TrackerStatsRow extends StatelessWidget {
  const TrackerStatsRow({super.key, required this.tracker});

  final StoryTracker tracker;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    if (!tracker.hasStats) {
      return Text(_fallbackLine(tracker), style: caps(size: 9.5, color: bite.faint));
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _Stat(
          value: '${tracker.articleCount}',
          label: tracker.articleCount == 1 ? 'development' : 'developments',
        ),
        const _StatDivider(),
        _Stat(
          value: '${tracker.sourceCount}',
          label: tracker.sourceCount == 1 ? 'outlet' : 'outlets',
        ),
        const _StatDivider(),
        _Stat(
          value: _spanValue(tracker),
          label: tracker.isStale ? 'quiet' : 'running',
        ),
      ],
    );
  }

  static String _fallbackLine(StoryTracker t) {
    final count =
        '${t.articleCount} ${t.articleCount == 1 ? 'story' : 'stories'}';
    if (t.isStale) return '$count  ·  quiet for ${t.daysQuiet} days';
    final at = t.latestAt;
    return at == null ? count : '$count  ·  ${relativeTime(at)}';
  }

  /// A stale story reports how long it has been silent; a live one reports how
  /// long it has been running. Same slot, because those are the two things
  /// worth knowing and only one applies at a time.
  static String _spanValue(StoryTracker t) {
    if (t.isStale) return _compact(t.sinceActivity);
    final span = t.span;
    if (span == null || span.inHours < 1) return 'new';
    return _compact(span);
  }

  static String _compact(Duration d) {
    if (d.inDays >= 7) return '${(d.inDays / 7).floor()}w';
    if (d.inDays >= 1) return '${d.inDays}d';
    return '${d.inHours}h';
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: display(size: 19, weight: 620, height: 1.1)),
        const SizedBox(height: 2),
        Text(label.toUpperCase(), style: caps(size: 8.5, color: bite.faint)),
      ],
    );
  }
}

class _StatDivider extends StatelessWidget {
  const _StatDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 0.75,
      height: 26,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      color: context.bite.border,
    );
  }
}

/// The most recent thing to happen on a followed story, attributed to the
/// outlet that filed it.
class _LatestDevelopment extends StatelessWidget {
  const _LatestDevelopment({required this.tracker});

  final StoryTracker tracker;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    final latest = tracker.latestTitle;

    if (latest == null) {
      return Row(
        children: [
          Icon(Icons.schedule, size: 14, color: bite.faint),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tracker.seedSource == null
                  ? 'No developments yet'
                  : 'No developments yet · from ${tracker.seedSource}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: sans(size: 12.5, color: bite.faint),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: tracker.isStale ? bite.faint : bite.accent,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                _attribution(tracker),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: caps(size: 9, color: bite.muted),
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: bite.faint),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          latest,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: sans(size: 13.5, wght: 450, height: 1.4, color: bite.body),
        ),
      ],
    );
  }

  String _attribution(StoryTracker t) {
    final when = t.latestAt == null ? '' : relativeTime(t.latestAt!);
    final who = t.latestSource;
    if (who == null || who.isEmpty) return 'LATEST  ·  $when';
    return 'LATEST  ·  $who  ·  $when';
  }
}

class _EmptyTracked extends StatelessWidget {
  const _EmptyTracked();

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.track_changes, size: 40, color: bite.faint),
            const SizedBox(height: 14),
            Text('Follow a story', style: display(size: 22, weight: 600)),
            const SizedBox(height: 8),
            Text(
              'Open any story and tap the bell to follow it. '
              'New developments on it collect here — a running timeline, '
              'separate from your feed.',
              textAlign: TextAlign.center,
              style: sans(size: 13.5, height: 1.5, color: bite.muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact relative time for tracker rows and timeline entries.
String relativeTime(DateTime at) {
  final d = DateTime.now().difference(at);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return '${(d.inDays / 7).floor()}w ago';
}
