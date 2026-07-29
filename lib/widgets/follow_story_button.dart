import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/article.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// "Follow this story" affordance: a circular toggle that seeds a Phase 13
/// tracker from the article. Follow-only (unfollowing lives in tracker
/// management, behind a confirm, so history isn't lost by a stray tap) — once
/// following, it shows a filled accent state and a tap just reaffirms it.
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
    final bite = context.bite;
    final following = state.isFollowing(article.id);
    final atCap = state.trackers.length >= AppState.maxTrackers;

    return Material(
      color: following ? bite.accent : Colors.transparent,
      shape: following
          ? const CircleBorder()
          : CircleBorder(side: BorderSide(color: bite.border, width: 0.75)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () {
          if (following) {
            HapticFeedback.selectionClick();
            _snack(context, 'Following this story');
            return;
          }
          if (atCap) {
            _snack(context,
                'You can follow up to ${AppState.maxTrackers} stories.');
            return;
          }
          HapticFeedback.mediumImpact();
          state.followStory(article);
          _snack(context, 'Following — new developments land in Tracked');
        },
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(
            following ? Icons.notifications_active : Icons.notifications_none,
            size: 20,
            color: following ? bite.onAccent : bite.ink,
          ),
        ),
      ),
    );
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
