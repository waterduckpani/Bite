import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_card_swiper/flutter_card_swiper.dart';

import '../data/practice_articles.dart';
import '../models/article.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../widgets/article_card.dart';
import '../widgets/bite_tab_bar.dart';
import '../widgets/follow_story_button.dart';
import '../widgets/glass.dart';
import '../widgets/pressable.dart';
import '../widgets/saved_tile.dart';
import '../widgets/walkthrough_cues.dart';

/// The Phase 17 interactive walkthrough: learn Bite by doing it.
///
/// # Nothing here touches real data
///
/// This is the hard constraint the whole screen is built around. The
/// walkthrough calls exactly ONE method on [AppState], and only at the very
/// end: [AppState.markGestureTutorialSeen]. It never calls readCard,
/// rejectCard, saveCard, openCard, followStory, recordImpression or
/// recordLinkOut, so no swipe_events row is written, no taste vector moves, no
/// save is made and no tracker is created. The deck it swipes is
/// [practiceArticles], which is not in the article pool and is never upserted.
/// The one piece of state a practice gesture produces (the followed badge)
/// lives in this widget's own [State] and is handed to [ArticleCard] through
/// its `following` override.
///
/// If you add a step, keep that property: a step teaches a gesture by
/// PERFORMING it on a practice card, not by running the real handler on a real
/// one.
///
/// # Two halves
///
/// 1. Gesture practice on a sandboxed deck, one gesture at a time, each with a
///    looping hint that keeps asking until the gesture actually happens.
/// 2. A tour of the five screens, spotlighting one tab at a time on the real
///    [BiteTabBar] and waiting for a real tap on it.
///
/// Skippable at every step, from a control that never moves.
class WalkthroughScreen extends StatefulWidget {
  const WalkthroughScreen({super.key});

  @override
  State<WalkthroughScreen> createState() => _WalkthroughScreenState();
}

/// Ordered; [_Step.values.length] is the progress denominator and
/// `_step.index` the numerator, so adding a step needs no counter updates.
enum _Step {
  intro,
  swipeRight,
  swipeLeft,
  openStory,
  saveStory,
  trackStory,
  tourFeed,
  tourSaved,
  tourTracked,
  tourDiscover,
  tourProfile,
  recap,
}

extension on _Step {
  bool get isPractice =>
      index >= _Step.intro.index && index <= _Step.trackStory.index;

  bool get isTour =>
      index >= _Step.tourFeed.index && index <= _Step.tourProfile.index;

  /// Which tab this tour step is asking for, or null outside the tour.
  int? get tourTab => isTour ? index - _Step.tourFeed.index : null;
}

class _WalkthroughScreenState extends State<WalkthroughScreen> {
  /// Dev convenience: `--dart-define=BITE_WALKTHROUGH_STEP=n` opens the
  /// walkthrough at step n, for simulator screenshots of a step that would
  /// otherwise need the gesture before it performed. The simulator has no tap
  /// tooling here, so without this only the first step is reachable.
  _Step _step = _Step.values[const int.fromEnvironment('BITE_WALKTHROUGH_STEP')
      .clamp(0, _Step.values.length - 1)];

  /// Index into [practiceArticles] of the card currently on top, so the
  /// link-out confirmation can name the right publisher.
  int _topCard = 0;

  /// The sandboxed followed state. Never a tracker, never persisted, gone the
  /// moment this screen is.
  bool _practiceFollowing = false;

  /// The gentle re-prompt after a wrong gesture. Never blocks anything; it
  /// just says what to try instead.
  String? _nudge;

  /// The success flash: shown between doing the thing and advancing.
  _Confirmation? _confirmation;

  /// Whether the tour step's tab has been tapped yet. Until it has, the
  /// spotlight is up and the panel is waiting.
  bool _arrived = false;

  /// The tour's own tab selection. Starts on nothing: the first thing the tour
  /// asks for is a tap on Feed, and a bar that already looks selected is not
  /// asking for anything.
  int _tourTab = -1;

  final List<GlobalKey> _tabKeys =
      List.generate(BiteTabBar.tabCount, (_) => GlobalKey());

  /// The spotlight cut-out, in global coordinates. Measured from the real tab
  /// bar after layout rather than computed from assumed geometry.
  Rect? _hole;

  Timer? _advanceTimer;
  Timer? _nudgeTimer;

  @override
  void dispose() {
    _advanceTimer?.cancel();
    _nudgeTimer?.cancel();
    super.dispose();
  }

  Article get _article => practiceArticles[_topCard];

  // -- Step machine -----------------------------------------------------------

  void _goTo(_Step step) {
    _advanceTimer?.cancel();
    _nudgeTimer?.cancel();
    setState(() {
      _step = step;
      _nudge = null;
      _confirmation = null;
      _arrived = false;
      _hole = null;
    });
  }

  void _next() {
    final next = _step.index + 1;
    if (next >= _Step.values.length) {
      _finish();
      return;
    }
    _goTo(_Step.values[next]);
  }

  /// Confirms the action just performed, then advances. The pause is the
  /// point: the gesture, the haptic and the label have to land together, or
  /// the lesson is "something happened" rather than "I saved that".
  void _succeed(_Confirmation confirmation, {Duration? hold}) {
    HapticFeedback.mediumImpact();
    _nudgeTimer?.cancel();
    setState(() {
      _confirmation = confirmation;
      _nudge = null;
    });
    _advanceTimer?.cancel();
    _advanceTimer = Timer(hold ?? const Duration(milliseconds: 900), () {
      if (mounted) _next();
    });
  }

  /// A wrong gesture is answered, never punished: a light haptic, a line of
  /// help, and the hint carries on looping. The card springs back on its own.
  void _nudgeUser(String message) {
    HapticFeedback.selectionClick();
    _nudgeTimer?.cancel();
    setState(() => _nudge = message);
    _nudgeTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _nudge = null);
    });
  }

  void _finish() {
    _advanceTimer?.cancel();
    _nudgeTimer?.cancel();
    // The single write this screen makes, and it is about the walkthrough
    // itself rather than about any story in it.
    AppScope.of(context).markGestureTutorialSeen();
  }

  void _skip() {
    HapticFeedback.lightImpact();
    _finish();
  }

  // -- Practice deck ----------------------------------------------------------

  /// The gesture this step is waiting for, or null for steps that aren't
  /// asking for a swipe.
  CardSwiperDirection? get _wanted => switch (_step) {
        _Step.swipeRight => CardSwiperDirection.right,
        _Step.swipeLeft => CardSwiperDirection.left,
        _Step.openStory => CardSwiperDirection.top,
        _Step.saveStory => CardSwiperDirection.bottom,
        _ => null,
      };

  bool _onSwipe(int previous, int? current, CardSwiperDirection direction) {
    if (_confirmation != null) return false;
    final wanted = _wanted;
    if (wanted == null) {
      _nudgeUser(_step == _Step.trackStory
          ? 'Not this time. Tap the bell below to follow this story.'
          : 'Tap Start when you are ready and we will take the gestures one '
              'at a time.');
      return false;
    }
    if (direction != wanted) {
      _nudgeUser(_wrongGestureMessage(direction));
      return false;
    }

    // The up-swipe is non-terminal in the real deck, so it is non-terminal
    // here too: the card stays, exactly as it would after coming back from
    // the publisher. Everything else resolves the card and moves the deck on.
    final consumes = direction != CardSwiperDirection.top;
    if (consumes && current != null && current < practiceArticles.length) {
      _topCard = current;
    }
    _succeed(_confirmationFor(direction),
        hold: direction == CardSwiperDirection.top
            // Long enough to read where it would have taken you.
            ? const Duration(milliseconds: 1500)
            : null);
    return consumes;
  }

  String _wrongGestureMessage(CardSwiperDirection got) {
    final tried = switch (got) {
      CardSwiperDirection.left => 'That was a swipe left',
      CardSwiperDirection.right => 'That was a swipe right',
      CardSwiperDirection.top => 'That was a swipe up',
      CardSwiperDirection.bottom => 'That was a swipe down',
      _ => 'Not quite',
    };
    return '$tried. Try ${_gestureName(_step)} this time.';
  }

  static String _gestureName(_Step step) => switch (step) {
        _Step.swipeRight => 'a swipe right',
        _Step.swipeLeft => 'a swipe left',
        _Step.openStory => 'a swipe up, or a tap',
        _Step.saveStory => 'a swipe down',
        _ => 'the gesture shown',
      };

  _Confirmation _confirmationFor(CardSwiperDirection direction) {
    final bite = context.bite;
    return switch (direction) {
      CardSwiperDirection.right => _Confirmation(
          Icons.check_circle_rounded, 'Read, done', bite.accent),
      CardSwiperDirection.left =>
        _Confirmation(Icons.close_rounded, 'Not interested', bite.danger),
      CardSwiperDirection.bottom => _Confirmation(
          Icons.bookmark_add_rounded, 'Saved for later', bite.ink),
      // Demonstrated, not navigated: the walkthrough says where the gesture
      // goes and stays put, so the practice run is never interrupted by a real
      // publisher page.
      _ => _Confirmation(Icons.open_in_new_rounded,
          'Opens at ${_article.source}', bite.accent),
    };
  }

  void _onTapCard() {
    if (_confirmation != null) return;
    if (_step == _Step.openStory) {
      _succeed(_confirmationFor(CardSwiperDirection.top),
          hold: const Duration(milliseconds: 1500));
      return;
    }
    if (_step == _Step.trackStory) {
      _nudgeUser('A tap opens the story. Tap the bell below to follow it.');
      return;
    }
    if (_step.isPractice && _step != _Step.intro) {
      _nudgeUser('A tap opens the story. This one wants '
          '${_gestureName(_step)}.');
    }
  }

  void _onTrackTapped() {
    if (_practiceFollowing || _confirmation != null) return;
    setState(() => _practiceFollowing = true);
    _succeed(
      _Confirmation(
          Icons.notifications_active, 'Following this story', context.bite.accent),
      hold: const Duration(milliseconds: 1200),
    );
  }

  // -- Screen tour ------------------------------------------------------------

  void _onTabTapped(int index) {
    final wanted = _step.tourTab;
    if (wanted == null || _confirmation != null) return;
    if (index != wanted) {
      _nudgeUser('That is ${BiteTabBar.tabLabels[index]}. '
          'Tap ${BiteTabBar.tabLabels[wanted]} to carry on.');
      return;
    }
    HapticFeedback.mediumImpact();
    _nudgeTimer?.cancel();
    setState(() {
      _tourTab = index;
      _arrived = true;
      _nudge = null;
    });
  }

  /// Reads the spotlight target out of the laid-out tab bar. Scheduled after
  /// the frame because the keys have no render object until then, and it
  /// settles after one pass because it only calls setState when the rectangle
  /// actually changed.
  void _measureHole() {
    final wanted = _step.tourTab;
    if (wanted == null || _arrived) {
      if (_hole != null) setState(() => _hole = null);
      return;
    }
    final box = _tabKeys[wanted].currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final rect = (box.localToGlobal(Offset.zero) & box.size).inflate(6);
    if (rect != _hole) setState(() => _hole = rect);
  }

  // -- Build ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_step.isTour) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _measureHole();
      });
    }
    return Scaffold(
      body: switch (_step) {
        _Step.recap => _recap(context),
        final s when s.isTour => _tour(context),
        _ => _practice(context),
      },
    );
  }

  // -- Practice half ----------------------------------------------------------

  /// Reserved for the floating instruction panel, mirroring how the live feed
  /// reserves room for the tab bar. Fixed rather than measured so the deck box
  /// does not resize between steps as the copy changes length.
  static const double _kPanelReserve = 158;
  static const double _kHeaderHeight = 52;

  Widget _practice(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final topInset = padding.top + 4 + _kHeaderHeight + 44;
    final bottomInset = padding.bottom + _kPanelReserve;
    // The hint stops the moment the gesture lands, so the confirmation is
    // never competing with an instruction to do the thing already done.
    final hint = _confirmation == null ? _hintFor(_step) : null;

    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.only(top: topInset, bottom: bottomInset),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _deck(),
                  if (hint case final h?)
                    SwipeHint(gesture: h.$1, color: h.$2),
                  if (_confirmation case final c?) _ConfirmationFlash(data: c),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          top: padding.top + 4,
          left: 16,
          right: 16,
          child: _header(context),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: padding.bottom + 12,
          child: _panel(context),
        ),
      ],
    );
  }

  Widget _deck() => CardSwiper(
        // Same swiper, same numbers as the live deck: the practice cards have
        // to move under the thumb exactly like the real ones, or the muscle
        // memory this builds is for a different app.
        key: const ValueKey('walkthrough-deck'),
        cardsCount: practiceArticles.length,
        numberOfCardsDisplayed: math.min(2, practiceArticles.length),
        backCardOffset: const Offset(0, -32),
        scale: 0.94,
        padding: EdgeInsets.zero,
        isLoop: false,
        // Every direction stays enabled on every step, including the wrong
        // ones. A wrong swipe has to be POSSIBLE for it to be answered with a
        // nudge; disabling it would teach nothing and feel broken.
        allowedSwipeDirection: const AllowedSwipeDirection.only(
          left: true,
          right: true,
          up: true,
          down: true,
        ),
        onSwipe: _onSwipe,
        cardBuilder: (context, index, hPct, vPct) => GestureDetector(
          onTap: _onTapCard,
          child: ArticleCard(
            article: practiceArticles[index],
            // The sandbox, made structural: with this set the card never
            // consults the real tracker list.
            following: _practiceFollowing && index == _topCard,
          ),
        ),
      );

  /// The looping hint for a step, as (direction, colour). The colour matches
  /// the drag cue the gesture will produce, so the hint and the outcome are
  /// visibly the same thing.
  (HintGesture, Color)? _hintFor(_Step step) {
    final bite = context.bite;
    return switch (step) {
      _Step.swipeRight => (HintGesture.right, bite.accent),
      _Step.swipeLeft => (HintGesture.left, bite.danger),
      _Step.openStory => (HintGesture.up, bite.accent),
      _Step.saveStory => (HintGesture.down, bite.ink),
      _ => null,
    };
  }

  Widget _header(BuildContext context) {
    final bite = context.bite;
    return GlassSurface(
      child: SizedBox(
        height: _kHeaderHeight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Getting started',
                        style: sans(
                            size: 13,
                            weight: FontWeight.w600,
                            color: bite.ink)),
                    const SizedBox(height: 5),
                    _ProgressTrack(
                      value: (_step.index + 1) / _Step.values.length,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Always here, on every step, in the same place. A skip that
              // moves around is a skip a hurried reader cannot find.
              TextButton(
                onPressed: _skip,
                child: Text('Skip',
                    style: sans(
                        size: 13.5,
                        weight: FontWeight.w600,
                        color: bite.muted)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _panel(BuildContext context) {
    final bite = context.bite;
    final (title, detail) = _copyFor(_step);
    return GlassSurface(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: display(size: 20, weight: 620)),
            const SizedBox(height: 6),
            Text(detail,
                style: sans(size: 13, color: bite.muted, height: 1.45)),
            if (_step == _Step.intro) ...[
              const SizedBox(height: 14),
              Pressable(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48)),
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    _next();
                  },
                  child: const Text('Start'),
                ),
              ),
            ],
            if (_step == _Step.trackStory) ...[
              const SizedBox(height: 14),
              _PracticeActionBar(
                following: _practiceFollowing,
                onTrack: _onTrackTapped,
              ),
            ],
            if (_nudge case final n?) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.replay_rounded, size: 15, color: bite.danger),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(n,
                        style: sans(
                            size: 12.5, color: bite.danger, height: 1.4)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  (String, String) _copyFor(_Step step) => switch (step) {
        _Step.intro => (
            'This is a card',
            'Every card is one story, summarised to about twenty seconds of '
                'reading. Four swipes decide what happens to it. These five '
                'cards are for practice, so nothing you do here counts.',
          ),
        _Step.swipeRight => (
            'Swipe right to say read, done',
            'You got the bite and you are happy to move on. Right means read, '
                'not saved.',
          ),
        _Step.swipeLeft => (
            'Swipe left for not interested',
            'The only way to ask for less of something. Bite quietly ranks '
                'stories like it lower.',
          ),
        _Step.openStory => (
            'Swipe up, or tap, to open it',
            'The bite informs you, the publisher completes it. Every story '
                'opens on their own page, and the card waits here for you.',
          ),
        _Step.saveStory => (
            'Swipe down to save it',
            'Down means save, not dismiss. It goes to your Saved list and '
                'stays there until you remove it.',
          ),
        _Step.trackStory => (
            'Follow a developing story',
            'Open a story and this bar sits at the bottom of it. Tap the bell '
                'to follow the story, and every new piece of coverage on it '
                'collects in Tracked.',
          ),
        _ => ('', ''),
      };

  // -- Tour half --------------------------------------------------------------

  Widget _tour(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final tab = _step.tourTab!;
    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.only(
              top: padding.top + 4 + _kHeaderHeight + 24,
              bottom: padding.bottom + kBiteTabBarReserved + 12,
              left: 20,
              right: 20,
            ),
            child: _TourPanel(
              tab: tab,
              arrived: _arrived,
              onNext: () {
                HapticFeedback.lightImpact();
                _next();
              },
            ),
          ),
        ),
        Positioned(
          top: padding.top + 4,
          left: 16,
          right: 16,
          child: _header(context),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: BiteTabBar(
            index: _tourTab,
            itemKeys: _tabKeys,
            onChanged: _onTabTapped,
          ),
        ),
        // Painted above the panel and the bar, below nothing: it dims, it does
        // not intercept, so the tab underneath is tapped for real.
        if (!_arrived) SpotlightScrim(hole: _hole),
        if (!_arrived)
          Positioned(
            left: 24,
            right: 24,
            bottom: padding.bottom + kBiteTabBarReserved + 18,
            child: _TourCallout(
              label: BiteTabBar.tabLabels[tab],
              nudge: _nudge,
            ),
          ),
      ],
    );
  }

  // -- Recap ------------------------------------------------------------------

  Widget _recap(BuildContext context) {
    final bite = context.bite;
    final padding = MediaQuery.paddingOf(context);
    return Stack(
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
                28, padding.top + 4 + _kHeaderHeight + 28, 28, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('That is all of it', style: display(size: 32, weight: 640)),
                const SizedBox(height: 10),
                Text(
                  'Four swipes and a bell. Here they are one more time.',
                  style: sans(size: 14, color: bite.muted, height: 1.5),
                ),
                const SizedBox(height: 26),
                _RecapRow(
                  icon: Icons.east_rounded,
                  badge: Icons.check_circle_rounded,
                  color: bite.accent,
                  title: 'Swipe right',
                  detail: 'Read, done, moving on.',
                ),
                _RecapRow(
                  icon: Icons.west_rounded,
                  badge: Icons.close_rounded,
                  color: bite.danger,
                  title: 'Swipe left',
                  detail: 'Not interested. The only negative signal.',
                ),
                _RecapRow(
                  icon: Icons.north_rounded,
                  badge: Icons.open_in_full_rounded,
                  color: bite.accent,
                  title: 'Swipe up, or tap',
                  detail: 'Open the full story at the publisher.',
                ),
                _RecapRow(
                  icon: Icons.south_rounded,
                  badge: Icons.bookmark_add_rounded,
                  color: bite.ink,
                  title: 'Swipe down',
                  detail: 'Save it for later.',
                ),
                _RecapRow(
                  icon: Icons.notifications_none,
                  badge: Icons.track_changes,
                  color: bite.accent,
                  title: 'Tap the bell',
                  detail: 'Follow a story and collect what comes next.',
                ),
                const SizedBox(height: 20),
                Text(
                  'Next, pick the topics you want and where you are reading '
                  'from. Both are editable in Profile whenever you like.',
                  style: sans(size: 13, color: bite.muted, height: 1.5),
                ),
                const SizedBox(height: 24),
                Pressable(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                        minimumSize: const Size(double.infinity, 54)),
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      _finish();
                    },
                    child: const Text('Pick my topics'),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          top: padding.top + 4,
          left: 16,
          right: 16,
          child: _header(context),
        ),
      ],
    );
  }
}

/// What a completed step flashes up: glyph, wording, and the colour of the cue
/// the gesture produces on the live deck.
class _Confirmation {
  const _Confirmation(this.icon, this.label, this.color);

  final IconData icon;
  final String label;
  final Color color;
}

/// The success flash over the practice deck. Scales in on the same spring the
/// live drag cues use, so a confirmed practice gesture and a real one look
/// like the same event.
class _ConfirmationFlash extends StatelessWidget {
  const _ConfirmationFlash({required this.data});

  final _Confirmation data;

  @override
  Widget build(BuildContext context) {
    final reduced = reducedMotion(context);
    return IgnorePointer(
      child: Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: reduced ? 1 : 0.7, end: 1),
          duration: reduced ? Duration.zero : BiteMotion.standard,
          curve: BiteMotion.spring,
          builder: (context, t, child) =>
              Transform.scale(scale: t, child: child),
          child: GlassSurface(
            borderRadius: 18,
            tint: data.color.withValues(alpha: 0.22),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: data.color, width: 2),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(data.icon, size: 20, color: data.color),
                  const SizedBox(width: 8),
                  Text(
                    data.label,
                    style: sans(
                      size: 14,
                      weight: FontWeight.w700,
                      color: data.color,
                      spacing: 0.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A replica of the reader's bottom action bar, carrying the REAL follow
/// control with a sandboxed handler.
///
/// The other three controls are shown inert and dimmed. They are there because
/// the bell is only findable in context: teaching a bell floating on its own
/// would leave the reader hunting for it in an unfamiliar bar later.
class _PracticeActionBar extends StatelessWidget {
  const _PracticeActionBar(
      {required this.following, required this.onTrack});

  final bool following;
  final VoidCallback onTrack;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: bite.card,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: bite.border, width: 0.75),
      ),
      child: Row(
        children: [
          Expanded(
            child: Opacity(
              opacity: 0.4,
              child: Container(
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: bite.accent,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Text('Save',
                    style: sans(
                        size: 14.5,
                        weight: FontWeight.w600,
                        color: bite.onAccent)),
              ),
            ),
          ),
          const SizedBox(width: 12),
          PulseRing(
            active: !following,
            child: FollowGlyph(following: following, onTap: onTrack),
          ),
          const SizedBox(width: 12),
          Opacity(
            opacity: 0.4,
            child: Icon(Icons.ios_share, size: 20, color: bite.ink),
          ),
          const SizedBox(width: 14),
          Opacity(
            opacity: 0.4,
            child: Icon(Icons.open_in_browser, size: 20, color: bite.ink),
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}

/// The instruction that rides above the spotlight: which tab to tap, plus the
/// re-prompt when a different one was tapped.
class _TourCallout extends StatelessWidget {
  const _TourCallout({required this.label, required this.nudge});

  final String label;
  final String? nudge;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Tap $label',
          textAlign: TextAlign.center,
          style: display(size: 24, weight: 640, color: bite.onScrim),
        ),
        const SizedBox(height: 6),
        Text(
          nudge ?? 'Have a look, then carry on.',
          textAlign: TextAlign.center,
          style: sans(
            size: 13,
            height: 1.4,
            color: nudge == null
                ? bite.onScrim.withValues(alpha: 0.75)
                : bite.onScrim,
          ),
        ),
        const SizedBox(height: 12),
        Icon(Icons.keyboard_double_arrow_down_rounded,
            size: 24, color: bite.accent),
      ],
    );
  }
}

/// What one screen is for, with a small taste of what it looks like. Shown
/// dimmed under the spotlight before the tab is tapped, and lit with a Next
/// button once it has been.
class _TourPanel extends StatelessWidget {
  const _TourPanel(
      {required this.tab, required this.arrived, required this.onNext});

  final int tab;
  final bool arrived;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    final (icon, title, detail) = switch (tab) {
      0 => (
          Icons.style,
          'Feed',
          'Your deck. Today\'s stories, ranked for you, one card at a time. '
              'This is where the four swipes live.',
        ),
      1 => (
          Icons.bookmark,
          'Saved',
          'Everything you swipe down lands here, searchable and filterable by '
              'topic. Swipe a row away to remove it.',
        ),
      2 => (
          Icons.track_changes,
          'Tracked',
          'Stories you followed with the bell. Each one keeps a running '
              'timeline of new coverage, separate from your feed.',
        ),
      3 => (
          Icons.explore,
          'Discover',
          'Browse by topic rather than by deck, for when you want to go '
              'looking instead of being handed things.',
        ),
      _ => (
          Icons.person,
          'Profile',
          'Your topics, your region, and your algorithm: exactly what your '
              'swipes have taught the feed, in the numbers it actually ranks '
              'with.',
        ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 46,
          height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bite.accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, size: 23, color: bite.accent),
        ),
        const SizedBox(height: 16),
        Text(title, style: display(size: 30, weight: 640)),
        const SizedBox(height: 10),
        Text(detail, style: sans(size: 14, color: bite.muted, height: 1.55)),
        const SizedBox(height: 22),
        Expanded(child: SingleChildScrollView(child: _preview(context))),
        if (arrived)
          Pressable(
            child: FilledButton(
              style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 52)),
              onPressed: onNext,
              child: Text(tab == BiteTabBar.tabCount - 1
                  ? 'Nearly there'
                  : 'Next'),
            ),
          ),
      ],
    );
  }

  /// A small, honest taste of the screen. Built from the same widgets the real
  /// screens use where there is one (a saved row is a real [SavedTile]), and
  /// from plain shapes where a faithful copy would mean fabricating data.
  Widget _preview(BuildContext context) {
    final bite = context.bite;
    return switch (tab) {
      0 => Column(
          children: [
            for (final (i, height) in const [(0, 92.0), (1, 78.0)])
              Padding(
                padding: EdgeInsets.only(
                    left: i * 10.0, right: i * 10.0, bottom: 8),
                child: Container(
                  height: height,
                  decoration: BoxDecoration(
                    color: bite.card,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: bite.border, width: 0.75),
                  ),
                ),
              ),
          ],
        ),
      1 => SavedTile(article: practiceArticles.first, onTap: () {}),
      2 => Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: bite.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: bite.border, width: 0.75),
          ),
          child: Row(
            children: [
              Icon(Icons.notifications_active, size: 18, color: bite.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  practiceArticles[1].aiSummaryHook!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: sans(size: 13.5, weight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: bite.accent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text('3 NEW', style: caps(size: 8.5, color: bite.onAccent)),
              ),
            ],
          ),
        ),
      3 => Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in Category.values)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: bite.card,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: bite.border, width: 0.75),
                ),
                child: Text(c.label, style: sans(size: 12.5)),
              ),
          ],
        ),
      _ => Column(
          children: [
            for (final (label, share) in const [
              ('Science', 0.42),
              ('World', 0.31),
              ('Tech', 0.27),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                            child: Text(label, style: sans(size: 13))),
                        Text('${(share * 100).round()}%',
                            style: sans(size: 12, color: bite.muted)),
                      ],
                    ),
                    const SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: share,
                        minHeight: 5,
                        backgroundColor: bite.border,
                        valueColor: AlwaysStoppedAnimation(bite.accent),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
    };
  }
}

/// Slim progress track in the walkthrough header.
class _ProgressTrack extends StatelessWidget {
  const _ProgressTrack({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: value.clamp(0.0, 1.0)),
        duration: reducedMotion(context) ? Duration.zero : BiteMotion.gentle,
        curve: BiteMotion.easeOut,
        builder: (context, t, _) => LinearProgressIndicator(
          value: t,
          minHeight: 4,
          backgroundColor: bite.border,
          valueColor: AlwaysStoppedAnimation(bite.accent),
        ),
      ),
    );
  }
}

/// One line of the closing recap: the arrow, the cue badge it produces, and
/// what it means. Same visual language as the live drag cues.
class _RecapRow extends StatelessWidget {
  const _RecapRow({
    required this.icon,
    required this.badge,
    required this.color,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final IconData badge;
  final Color color;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 20, color: bite.faint),
                const SizedBox(width: 4),
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(badge, size: 16, color: color),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: sans(size: 14.5, weight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(detail, style: sans(size: 12.5, color: bite.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
