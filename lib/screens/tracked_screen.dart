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
                        trackers.isEmpty
                            ? 'Follow a story to watch it develop'
                            : '${trackers.length} ${trackers.length == 1 ? 'story' : 'stories'} followed',
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

/// A tracker list row that opens its timeline with a container transform.
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
            border: Border.all(color: bite.border, width: 0.75),
          ),
          padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (tracker.muted) ...[
                          Icon(Icons.notifications_off,
                              size: 15, color: bite.faint),
                          const SizedBox(width: 6),
                        ]
                        // A story that has gone quiet gets a marker here and a
                        // full prompt inside. Marker only — Bite suggests
                        // unfollowing, it never does it for you.
                        else if (tracker.isStale) ...[
                          Icon(Icons.history_toggle_off,
                              size: 15, color: bite.faint),
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
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tracker.latestTitle ?? 'No new developments yet',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: sans(
                        size: 13,
                        height: 1.4,
                        color: tracker.latestTitle == null
                            ? bite.faint
                            : bite.muted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _metaLine(tracker),
                      style: caps(size: 9.5, color: bite.faint),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (tracker.unreadCount > 0)
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
                    )
                  else
                    const SizedBox(height: 4),
                  const SizedBox(height: 10),
                  Icon(Icons.chevron_right, size: 20, color: bite.faint),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _metaLine(StoryTracker t) {
    final count = '${t.articleCount} ${t.articleCount == 1 ? 'story' : 'stories'}';
    // A quiet story says so plainly, in place of a timestamp that would read
    // as activity ("2 stories · 12 days ago" invites a second look; "quiet for
    // 12 days" says what it means).
    if (t.isStale) return '$count  ·  quiet for ${t.daysQuiet} days';
    final at = t.latestAt;
    if (at == null) return count;
    return '$count  ·  ${relativeTime(at)}';
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
