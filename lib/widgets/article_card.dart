import 'package:flutter/material.dart';

import '../models/article.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import 'category_chip.dart';
import 'cover_art.dart';
import 'reader_cue.dart';
import 'source_mark.dart';

// -- Card metrics -------------------------------------------------------------
// The card does not scroll — it is swiped — so the whole bite has to fit the
// space it is given. These constants are the layout budget: everything except
// the summary is fixed-ish, and the summary gets a line allowance computed from
// whatever is left over on the actual device (see [_ArticleCardBody]).
//
// They are tuned against the deck's REAL box, which is smaller than the screen
// suggests: 360.5 × 520.5 on an iPhone 17, once the floating header, the tab
// bar and the swiper's own insets are taken out. An 80-word bite is 12 lines
// at this width, and 12 lines have to fit with a cover still above them —
// that constraint is what sets the sizes below. article_card_layout_test.dart
// pins it; retune there if any of these change.

const double _kHookSize = 23;
const double _kHookHeight = 1.14;

/// The hook may run to three lines when there is room for it. Two is the
/// common case; the third exists because a hook that clips mid-word under a
/// half-empty cover is the single worst-looking state the card has.
const int _kHookMaxLines = 3;

const double _kBodySize = 13.5;
const double _kBodyHeightFactor = 1.5;

const double _kPadTop = 16;
const double _kPadBottom = 14;
const double _kGapHookBody = 8;
const double _kGapBodyCue = 12;
const double _kGapCueSource = 8;

/// Rendered height of [LinkOutCue]: 9pt vertical padding either side, one
/// 12.5pt line at 1.4, plus the 0.75 hairline top and bottom.
const double _kCueHeight = 9 * 2 + 12.5 * 1.4 + 0.75 * 2;

/// Rendered height of [SourceMark] — its lettermark avatar is the tallest
/// thing in the row.
const double _kSourceHeight = 20;

/// Everything in the text block that is neither the summary nor the hook.
/// The hook's height is measured rather than assumed, so a one-line hook hands
/// its spare line to the bite instead of reserving it.
const double _kFixedChrome = _kPadTop +
    _kGapHookBody +
    _kGapBodyCue +
    _kCueHeight +
    _kGapCueSource +
    _kSourceHeight +
    _kPadBottom;

/// Smallest slice of the card the cover may shrink to when the bite runs long.
/// A photo keeps a real band; a story with no image gets a slim on-brand strip
/// instead, which is both the placeholder and the extra room the text needs.
const double _kPhotoFloorFraction = 0.20;
const double _kPhotoFloorMin = 92;
const double _kPhotoFloorMax = 220;
const double _kNoPhotoBand = 76;

/// The big feed card. Since Phase 15.2 the AI bite IS the card: the hook is the
/// headline and the full 50–80 word summary is the body, both visible before
/// any interaction. Below them sits the persistent link-out to the publisher.
///
/// Nothing here scrolls, so the layout is inverted from the usual: the text
/// block takes the height it needs and the cover absorbs whatever is left.
/// A 40-word bite therefore yields a taller cover rather than a dead gap, and
/// an 80-word bite squeezes the cover down to its floor rather than clipping.
class ArticleCard extends StatelessWidget {
  const ArticleCard({super.key, required this.article, this.following});

  final Article article;

  /// Overrides the followed-state marker instead of reading it from
  /// [AppState]. Null (the default, and every live use) reads the real
  /// trackers.
  ///
  /// Exists for the Phase 17 walkthrough, whose practice cards must be able to
  /// show a followed badge without a tracker existing anywhere. Passing the
  /// state in is what keeps that promise structural: with an override set the
  /// card never touches [AppScope] at all, so the sandbox cannot leak into it
  /// by accident later.
  final bool? following;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Container(
      decoration: BoxDecoration(
        color: bite.card,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: bite.border, width: 0.75),
        boxShadow: [
          BoxShadow(
            color: bite.ink.withValues(alpha: 0.04),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Bounded in the swiper; the fallback only guards against being
          // measured in an unbounded box (e.g. an intrinsic-height parent).
          final cardHeight =
              constraints.maxHeight.isFinite ? constraints.maxHeight : 520.0;
          final coverFloor = article.hasImage
              ? (cardHeight * _kPhotoFloorFraction)
                  .clamp(_kPhotoFloorMin, _kPhotoFloorMax)
              : _kNoPhotoBand;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Takes the leftover: whatever the bite doesn't need.
              Expanded(child: _Cover(article: article, following: following)),
              // Capped so the cover can never be squeezed below its floor,
              // which is also what keeps the cue on-card at 80 words.
              ConstrainedBox(
                constraints:
                    BoxConstraints(maxHeight: cardHeight - coverFloor),
                child: _ArticleCardBody(
                  article: article,
                  budget: cardHeight - coverFloor,
                  width: constraints.maxWidth,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Cover slot: the photo when there is one, otherwise the category gradient as
/// a deliberate band rather than a blank or a broken-image glyph. Same widget
/// either way, so there is no layout jump between the two states.
class _Cover extends StatelessWidget {
  const _Cover({required this.article, this.following});

  final Article article;

  /// See [ArticleCard.following].
  final bool? following;

  @override
  Widget build(BuildContext context) {
    final isFollowing =
        following ?? AppScope.of(context).isFollowing(article.id);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Hero pair with the browser: on swipe-up the cover and headline
        // morph up into the opened screen.
        HeroMode(
          enabled: !reducedMotion(context),
          child: Hero(
            tag: article.coverHeroTag,
            child: CoverArt(article: article, showCredit: true),
          ),
        ),
        Positioned(
          top: 14,
          left: 14,
          child: CategoryChip(label: article.category.label),
        ),
        // Followed-state marker (Phase 13): shows this story is already
        // tracked, so it reads as followed and can't be double-followed.
        if (isFollowing)
          const Positioned(top: 14, right: 14, child: _FollowingBadge()),
      ],
    );
  }
}

/// Hook + bite + link-out + attribution.
class _ArticleCardBody extends StatelessWidget {
  const _ArticleCardBody({
    required this.article,
    required this.budget,
    required this.width,
  });

  final Article article;

  /// Vertical space this block may occupy, from which the summary's line
  /// allowance is derived.
  final double budget;

  /// Card width, used to measure how many lines the hook actually takes.
  final double width;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    // The feed only surfaces summarised articles (migration 0020), so the
    // no-summary path is a belt-and-braces fallback for saved/tracker rows
    // written before the gate. It shows the publisher headline and drops the
    // body entirely — never a raw publisher description, and never an empty
    // body block sitting there as a gap.
    final hasSummary = article.hasSummary;
    final lead = hasSummary ? article.aiSummaryHook! : article.headline;

    final hookStyle =
        display(size: _kHookSize, weight: 600, height: _kHookHeight);
    final scaler = MediaQuery.textScalerOf(context);

    // Measure the hook instead of reserving a worst case for it. One short
    // string per build, which is cheap next to the paragraph layout Flutter
    // does for the bite anyway — and it is what lets a one-line hook hand its
    // spare line to the bite, and a long hook take a third line rather than
    // clipping mid-word under a half-empty cover.
    final hookHeight = (TextPainter(
      text: TextSpan(text: lead, style: hookStyle),
      textDirection: Directionality.of(context),
      maxLines: _kHookMaxLines,
      textScaler: scaler,
    )..layout(maxWidth: width - 44))
        .height;

    // Text only ellipsises at maxLines, never at the height it was actually
    // given — asking for more lines than fit produces a hard CLIP mid-word,
    // not a graceful "…". So the allowance is computed, not guessed.
    final bodyLine = scaler.scale(_kBodySize) * _kBodyHeightFactor;
    final bodyLines =
        ((budget - _kFixedChrome - hookHeight) / bodyLine).floor().clamp(3, 18);

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, _kPadTop, 22, _kPadBottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HeroMode(
            enabled: !reducedMotion(context),
            child: Hero(
              tag: article.headlineHeroTag,
              child: Material(
                type: MaterialType.transparency,
                child: Text(
                  lead,
                  maxLines: _kHookMaxLines,
                  overflow: TextOverflow.ellipsis,
                  style: hookStyle,
                ),
              ),
            ),
          ),
          if (hasSummary) ...[
            const SizedBox(height: _kGapHookBody),
            Text(
              article.aiSummary!,
              maxLines: bodyLines,
              overflow: TextOverflow.ellipsis,
              style: sans(
                size: _kBodySize,
                // The bite is the card's substance, not a caption — it carries
                // near-ink weight and colour so it competes with the hook
                // instead of receding behind it.
                wght: 450,
                height: _kBodyHeightFactor,
                color: bite.body,
              ),
            ),
          ],
          const SizedBox(height: _kGapBodyCue),
          // Every story carries a persistent, prominent route to the
          // publisher directly under the bite.
          LinkOutCue(article: article),
          const SizedBox(height: _kGapCueSource),
          SourceMark(article: article),
        ],
      ),
    );
  }
}

/// A small "Following" pill shown on the cover of a tracked story.
class _FollowingBadge extends StatelessWidget {
  const _FollowingBadge();

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bite.accent,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.notifications_active, size: 12, color: bite.onAccent),
          const SizedBox(width: 4),
          Text('Following', style: caps(size: 9, color: bite.onAccent)),
        ],
      ),
    );
  }
}
