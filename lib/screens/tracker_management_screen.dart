import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/story_tracker.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/pressable.dart';

/// Manage followed stories: rename, mute (stop matching new articles without
/// losing history), and unfollow (delete, with confirm). Deleting a tracker
/// removes only its timeline rows — never the underlying articles, saves, or
/// swipe history.
class TrackerManagementScreen extends StatelessWidget {
  const TrackerManagementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final bite = context.bite;
    final trackers = state.trackers;
    final bottomPad = 24 + MediaQuery.paddingOf(context).bottom;

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
                children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back, color: bite.ink),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 2),
                  Text('Manage trackers',
                      style: display(size: 22, weight: 620)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: trackers.isEmpty
                  ? Center(
                      child: Text('No trackers to manage',
                          style: sans(size: 14, color: bite.muted)),
                    )
                  : ListView.separated(
                      padding: EdgeInsets.fromLTRB(20, 4, 20, bottomPad),
                      itemCount: trackers.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, i) =>
                          _ManageRow(tracker: trackers[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ManageRow extends StatelessWidget {
  const _ManageRow({required this.tracker});

  final StoryTracker tracker;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final bite = context.bite;
    return Container(
      decoration: BoxDecoration(
        color: bite.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: bite.border, width: 0.75),
      ),
      padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tracker.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: display(size: 16.5, weight: 600, height: 1.15),
          ),
          const SizedBox(height: 6),
          Text(
            '${_created(tracker.createdAt)}  ·  '
            '${tracker.articleCount} ${tracker.articleCount == 1 ? 'story' : 'stories'} matched',
            style: caps(size: 9.5, color: bite.faint),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _Action(
                icon: Icons.edit_outlined,
                label: 'Rename',
                onTap: () => _rename(context, state),
              ),
              const SizedBox(width: 6),
              _Action(
                icon: tracker.muted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
                label: tracker.muted ? 'Unmute' : 'Mute',
                onTap: () {
                  HapticFeedback.selectionClick();
                  state.setTrackerMuted(tracker.id, !tracker.muted);
                },
              ),
              const Spacer(),
              _Action(
                icon: Icons.delete_outline,
                label: 'Unfollow',
                danger: true,
                onTap: () => _confirmDelete(context, state),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _created(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return 'Followed ${months[dt.month - 1]} ${dt.day}';
  }

  Future<void> _rename(BuildContext context, AppState state) async {
    final controller = TextEditingController(text: tracker.title);
    final bite = context.bite;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: bite.card,
        title: Text('Rename tracker', style: display(size: 18, weight: 600)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 2,
          minLines: 1,
          style: sans(size: 14, color: bite.ink),
          decoration: InputDecoration(
            hintText: 'Tracker name',
            hintStyle: sans(size: 14, color: bite.faint),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: bite.border, width: 0.75),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: bite.accent),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel', style: sans(size: 14, color: bite.muted)),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      state.renameTracker(tracker.id, result);
    }
  }

  Future<void> _confirmDelete(BuildContext context, AppState state) async {
    final bite = context.bite;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: bite.card,
        title: Text('Unfollow this story?',
            style: display(size: 18, weight: 600)),
        content: Text(
          'This removes the tracker and its timeline. Your saved stories and '
          'reading history are not affected.',
          style: sans(size: 13.5, height: 1.45, color: bite.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: sans(size: 14, color: bite.muted)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: bite.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Unfollow'),
          ),
        ],
      ),
    );
    if (ok == true) {
      HapticFeedback.mediumImpact();
      state.deleteTracker(tracker.id);
    }
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    final color = danger ? bite.danger : bite.ink;
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: (danger ? bite.danger : bite.muted).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Text(label,
                style: sans(size: 12.5, weight: FontWeight.w600, color: color)),
          ],
        ),
      ),
    );
  }
}
