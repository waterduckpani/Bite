import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/article.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// "Follow this story" affordance: a circular toggle that seeds a Phase 13
/// tracker from the article, and unfollows it again on a second tap.
///
/// Unfollowing takes the tracker's whole timeline with it, so it goes behind a
/// confirm rather than happening on a stray tap — but it does happen HERE.
/// Burying it in tracker management meant the button that turned following on
/// was not the button that turned it off, which is the one thing a toggle may
/// not do.
///
/// Lived on the native reader until Phase 15.1 removed it. It moved here
/// rather than going with it: this is the ONLY place in the app a story can
/// be followed, so deleting the reader would otherwise have quietly deleted
/// the entrance to trackers.
class FollowStoryButton extends StatelessWidget {
  const FollowStoryButton({super.key, required this.article});

  final Article article;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final following = state.isFollowing(article.id);
    final atCap = state.trackers.length >= AppState.maxTrackers;

    return FollowGlyph(
      following: following,
      onTap: () {
        if (following) {
          HapticFeedback.selectionClick();
          _confirmUnfollow(context, state);
          return;
        }
        if (atCap) {
          _snack(
              context, 'You can follow up to ${AppState.maxTrackers} stories.');
          return;
        }
        HapticFeedback.mediumImpact();
        state.followStory(article);
        _snack(context, 'Following. New developments land in Tracked.');
      },
    );
  }

  /// Same confirm the tracker screens use — the timeline is the thing being
  /// destroyed, and it reads identically wherever the unfollow is triggered.
  Future<void> _confirmUnfollow(BuildContext context, AppState state) async {
    final tracker = state.trackerForArticle(article.id);
    final collected = tracker == null ? 0 : tracker.articleCount;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Stop following?'),
        content: Text(
          collected > 1
              ? 'This story and the $collected developments collected for it '
                  'will be removed from Tracked. Saved stories and your '
                  'reading history are unaffected.'
              : 'This story will be removed from Tracked. Saved stories and '
                  'your reading history are unaffected.',
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
    state.unfollowStory(article.id);
    _snack(context, 'No longer following this story');
  }

  void _snack(BuildContext context, String message) {
    final bite = context.bite;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message,
            style: sans(size: 13, weight: FontWeight.w500, color: bite.paper)),
        behavior: SnackBarBehavior.floating,
        backgroundColor: bite.ink,
        duration: const Duration(seconds: 2),
      ));
  }
}

/// The follow control's LOOK, with its state and its tap handed in.
///
/// Split out of [FollowStoryButton] so the Phase 17 walkthrough can teach the
/// control without wiring it to a real tracker. The practice bell is not a
/// drawing of this button, it IS this button: same circle, same fill, same
/// glyph swap, same 44pt target. If the real one is restyled the lesson
/// restyles with it, which is the only way a walkthrough stays true.
class FollowGlyph extends StatelessWidget {
  const FollowGlyph({super.key, required this.following, required this.onTap});

  final bool following;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Material(
      color: following ? bite.accent : Colors.transparent,
      shape: following
          ? const CircleBorder()
          : CircleBorder(side: BorderSide(color: bite.border, width: 0.75)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Semantics(
            button: true,
            label: following ? 'Stop following this story' : 'Follow this story',
            child: Icon(
              following ? Icons.notifications_active : Icons.notifications_none,
              size: 20,
              color: following ? bite.onAccent : bite.ink,
            ),
          ),
        ),
      ),
    );
  }
}
