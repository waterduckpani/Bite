import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_card_swiper/flutter_card_swiper.dart';

import '../models/article.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../widgets/article_card.dart';
import '../widgets/bite_tab_bar.dart';
import '../widgets/category_chip.dart';
import '../widgets/glass.dart';
import '../widgets/pressable.dart';
import 'browser_screen.dart';

class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  final CardSwiperController _controller = CardSwiperController();

  // Deck is snapshotted per epoch so saves/dismissals mid-swipe don't
  // reshuffle the cards under the swiper.
  List<Article> _deck = const [];
  int _epoch = -1;
  bool _finished = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _onSwipe(
      int previousIndex, int? currentIndex, CardSwiperDirection direction) {
    final state = AppScope.of(context);
    final article = _deck[previousIndex];
    // Top up before the deck runs dry: a cheap re-query of the ranked deck
    // from the database (never a news-API call), throttled in refreshFeed.
    // Skip on the non-terminal up-swipe — it doesn't consume a card.
    if (direction != CardSwiperDirection.top &&
        _deck.length - previousIndex <= 5) {
      state.refreshFeed();
    }
    // Phase 14 impression: the card that has just become the top of the deck
    // is the one actually being shown. The back card peeking behind it is
    // built by cardBuilder too, which is exactly why impressions are not
    // logged from there.
    if (currentIndex != null && currentIndex < _deck.length) {
      state.recordImpression(_deck[currentIndex]);
    }
    switch (direction) {
      case CardSwiperDirection.left:
        // Not interested. The only negative signal.
        HapticFeedback.selectionClick();
        state.rejectCard(article);
        return true;
      case CardSwiperDirection.right:
        // Read, done, moving on — the common satisfied outcome.
        HapticFeedback.lightImpact();
        state.readCard(article);
        return true;
      case CardSwiperDirection.bottom:
        // Save for later.
        HapticFeedback.lightImpact();
        state.saveCard(article);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
            content: Text('Saved'),
            duration: Duration(milliseconds: 900),
          ));
        return true;
      case CardSwiperDirection.top:
        // Open the reader; cancel the swipe so the same card is still here
        // when the user returns to resolve it (non-terminal). Logs "opened".
        _openReader(state, article);
        return false;
      default:
        return false;
    }
  }

  /// Shared by the up-swipe and the tap: open the full story and log the
  /// additive "opened" signal, without resolving the card.
  void _openReader(AppState state, Article article) {
    state.openCard(article);
    BrowserScreen.open(context, article);
  }

  Widget _swiper() => CardSwiper(
        key: ValueKey(_epoch),
        controller: _controller,
        cardsCount: _deck.length,
        numberOfCardsDisplayed: math.min(2, _deck.length),
        backCardOffset: const Offset(0, -32),
        scale: 0.94,
        padding: EdgeInsets.zero,
        isLoop: false,
        allowedSwipeDirection: const AllowedSwipeDirection.only(
          left: true,
          right: true,
          up: true,
          down: true,
        ),
        onSwipe: _onSwipe,
        onEnd: () => setState(() => _finished = true),
        cardBuilder: (context, index, hPct, vPct) {
          final article = _deck[index];
          return GestureDetector(
            onTap: () => _openReader(AppScope.of(context), article),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ArticleCard(article: article),
                _SwipeCues(hPct: hPct, vPct: vPct),
              ],
            ),
          );
        },
      );

  /// Whether the next deck is REPLACING one (so it should animate in) rather
  /// than being the first deck this screen has ever shown.
  bool _entranceFromScratch = false;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    if (_epoch != state.deckEpoch) {
      final firstBuild = _epoch == -1;
      _epoch = state.deckEpoch;
      _deck = state.deck;
      _finished = _deck.isEmpty;
      // The first card of a rebuilt deck never goes through onSwipe, so its
      // impression is logged here. Deferred off the build phase because
      // recordImpression queues a write.
      if (_deck.isNotEmpty) {
        final first = _deck.first;
        WidgetsBinding.instance
            .addPostFrameCallback((_) => state.recordImpression(first));
      }
      // The entrance animation is NOT driven from here. See _DeckEntrance:
      // its state is keyed to the epoch, so a rebuilt deck gets a fresh
      // controller that starts at zero, and nothing has to mutate an
      // animation during build.
      _entranceFromScratch = !firstBuild;
    }

    final padding = MediaQuery.paddingOf(context);
    // Deck sits clear of the floating header (above) and tab bar (below).
    // The top gap absorbs the back card's upward peek (-32) so even the back
    // card keeps clear air under the header; the bottom leaves just enough
    // to float above the tab bar.
    final topInset = padding.top + 4 + _kFeedHeaderHeight + 56;
    final bottomInset = padding.bottom + kBiteTabBarReserved;

    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.only(top: topInset, bottom: bottomInset),
            child: state.status == ContentStatus.loading
                ? const _LoadingDeck()
                : _finished
                    ? _CaughtUp(
                        onReset: state.resetFeed,
                        onRefresh: () => state.refreshFeed(force: true),
                      )
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                        child: _DeckEntrance(
                          // A new epoch means a new State, and therefore a
                          // fresh controller starting at zero.
                          key: ValueKey(_epoch),
                          animate: _entranceFromScratch,
                          child: _swiper(),
                        ),
                      ),
          ),
        ),
        Positioned(
          top: padding.top + 4,
          left: 16,
          right: 16,
          child: _GlassHeader(onFilter: () => _showFilters(context)),
        ),
        // Phase 17 moved the first-run teaching OFF the live deck entirely.
        // It used to be a static coach-mark blurred over these cards; it is
        // now an interactive walkthrough on a sandboxed deck, run before this
        // screen is ever reached (see WalkthroughScreen). Nothing overlays the
        // real deck any more, so a real card is never swiped by accident while
        // learning what a swipe does.
      ],
    );
  }

  void _showFilters(BuildContext context) {
    final state = AppScope.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.bite.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => ListenableBuilder(
        listenable: state,
        builder: (context, _) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your feed', style: display(size: 24, weight: 600)),
                const SizedBox(height: 6),
                Text(
                  'Stories are pulled from the topics you follow.',
                  style: sans(size: 13, color: context.bite.muted),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in Category.values)
                      TopicPill(
                        label: c.label,
                        selected: state.selectedCategories.isEmpty ||
                            state.selectedCategories.contains(c),
                        onTap: () => state.toggleCategory(c),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Fades and settles a REBUILT deck in rather than letting it pop — a region
/// change (Phase 16, Part E), a feed reset, or fresh content arriving.
///
/// This is a separate widget KEYED TO THE DECK EPOCH, which is the whole point.
/// Driving the entrance from the parent's own controller meant the parent had
/// to reset that controller when the epoch changed, and the only place it knew
/// the epoch had changed was inside `build` — so it mutated an animation that
/// the FadeTransition below was already listening to, and Flutter threw
/// "setState() or markNeedsBuild() called during build" on every rebuilt deck.
/// Scheduling the reset post-frame would have fixed the exception but left the
/// new deck painting fully opaque for one frame before snapping to zero.
///
/// A fresh State per epoch has neither problem: the controller is created at
/// zero and started in initState, which is a legal place to begin an animation
/// because this widget's own listeners are not attached until its first build.
///
/// Under reduced motion the child is returned UNWRAPPED — no transition widgets
/// in the tree at all, not merely a zero-duration animation. That is the honest
/// reading of the preference, and it keeps the tree identical to the
/// pre-Phase-16 one when animations are off, which is what the gesture tests
/// exercise.
class _DeckEntrance extends StatefulWidget {
  const _DeckEntrance({super.key, required this.animate, required this.child});

  /// False for the very first deck this screen shows — there is nothing it is
  /// replacing, so it simply appears.
  final bool animate;
  final Widget child;

  @override
  State<_DeckEntrance> createState() => _DeckEntranceState();
}

class _DeckEntranceState extends State<_DeckEntrance>
    with SingleTickerProviderStateMixin {
  /// Created EAGERLY in initState, not as a lazy `late final`. Under reduced
  /// motion nothing ever reads it, so a lazy field would still be uninitialised
  /// when dispose() touched it — and the initialiser needs a Ticker, which
  /// cannot be created on a deactivated element. That throws "Looking up a
  /// deactivated widget's ancestor is unsafe" from inside dispose, which is a
  /// thoroughly misleading place to read it from.
  ///
  /// Starts settled, so a deck that turns out not to animate is never
  /// invisible, not even for a frame.
  late final AnimationController _in;
  late final Animation<double> _curve;

  /// Resolved once, in didChangeDependencies. Read by build, never written
  /// there.
  bool _resolved = false;
  bool _animating = false;

  @override
  void initState() {
    super.initState();
    _in = AnimationController(
      vsync: this,
      duration: BiteMotion.gentle,
      value: 1,
    );
    _curve = CurvedAnimation(parent: _in, curve: BiteMotion.easeOut);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // This runs BEFORE the first build, which is what makes it the right place:
    // reducedMotion needs MediaQuery (so initState is too early), and nothing
    // is listening to _curve yet (so rewinding and starting the controller
    // cannot mark anything dirty). Guarded to once — a theme change or metrics
    // change re-runs this, and it must not replay the entrance.
    if (_resolved) return;
    _resolved = true;
    _animating = widget.animate && !reducedMotion(context);
    if (_animating) {
      _in.value = 0;
      _in.forward();
    }
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_animating) return widget.child;
    return FadeTransition(
      opacity: _curve,
      child: ScaleTransition(
        scale: _curve.drive(Tween(begin: 0.97, end: 1.0)),
        child: widget.child,
      ),
    );
  }
}

/// Fixed height of the floating feed header, so the deck can be inset to sit
/// exactly below it.
const double _kFeedHeaderHeight = 52;

/// Floating glass header carrying the wordmark and the feed-filter control.
class _GlassHeader extends StatelessWidget {
  const _GlassHeader({required this.onFilter});

  final VoidCallback onFilter;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return GlassSurface(
      child: SizedBox(
        height: _kFeedHeaderHeight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
          child: Row(
            children: [
              Text('Bite', style: display(size: 24, weight: 640)),
              Text('.',
                  style: display(size: 24, weight: 700, color: bite.accent)),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.tune, size: 22, color: bite.ink),
                tooltip: 'Filter your feed',
                constraints:
                    const BoxConstraints.tightFor(width: 40, height: 40),
                padding: EdgeInsets.zero,
                onPressed: onFilter,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Directional cue overlays shown while dragging the top card.
class _SwipeCues extends StatelessWidget {
  const _SwipeCues({required this.hPct, required this.vPct});

  final int hPct;
  final int vPct;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    final l = (-hPct / 40).clamp(0.0, 1.0); // dragging left  → not interested
    final r = (hPct / 40).clamp(0.0, 1.0); //  dragging right → read
    final u = (-vPct / 40).clamp(0.0, 1.0); // dragging up    → open
    final d = (vPct / 40).clamp(0.0, 1.0); //  dragging down  → save
    // A diagonal drag resolves to a single axis: whichever of horizontal /
    // vertical dominates shows its cue, the other is suppressed. Ties fall to
    // horizontal (the two most common gestures, reject/read).
    final horiz = math.max(l, r);
    final vert = math.max(u, d);
    final left = horiz >= vert ? l : 0.0;
    final right = horiz >= vert ? r : 0.0;
    final up = vert > horiz ? u : 0.0;
    final down = vert > horiz ? d : 0.0;

    return IgnorePointer(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (left > 0)
              _cueScrim(context, bite.danger, left,
                  alignment: Alignment.topRight,
                  child: _cueBadge(
                      'NOT INTERESTED', Icons.close_rounded, bite.danger, left,
                      angle: 0.12)),
            if (right > 0)
              _cueScrim(context, bite.accent, right,
                  alignment: Alignment.topLeft,
                  child: _cueBadge(
                      'READ', Icons.check_circle_rounded, bite.accent, right,
                      angle: -0.12)),
            if (down > 0)
              _cueScrim(context, bite.ink, down,
                  alignment: Alignment.topCenter,
                  child: _cueBadge(
                      'SAVE', Icons.bookmark_add_rounded, bite.ink, down)),
            if (up > 0)
              _cueScrim(context, bite.accent, up,
                  alignment: Alignment.bottomCenter,
                  child: _cueBadge(
                      'OPEN', Icons.open_in_full_rounded, bite.accent, up)),
          ],
        ),
      ),
    );
  }

  Widget _cueScrim(BuildContext context, Color color, double t,
      {required Alignment alignment, required Widget child}) {
    // The badge springs in with the drag: scale rides an easeOutBack of the
    // drag progress so it lands with a little overshoot instead of popping.
    final scale = reducedMotion(context)
        ? 1.0
        : 0.7 + 0.3 * BiteMotion.spring.transform(t);
    return Container(
      color: color.withValues(alpha: 0.10 * t),
      alignment: alignment,
      padding: const EdgeInsets.all(24),
      child: Opacity(
        opacity: t,
        child: Transform.scale(scale: scale, child: child),
      ),
    );
  }

  Widget _cueBadge(String label, IconData icon, Color color, double t,
      {double angle = 0}) {
    return Transform.rotate(
      angle: angle,
      // Glass badge floating over the card cover; the coloured hairline and
      // label ride crisply on top of the frosted surface.
      child: GlassSurface(
        borderRadius: 12,
        blur: 8,
        tint: color.withValues(alpha: 0.22),
        bordered: false,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color, width: 2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: sans(
                  weight: FontWeight.w700,
                  color: color,
                  spacing: 1.5,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Card-shaped placeholder shown while the first live fetch is in flight.
class _LoadingDeck extends StatelessWidget {
  const _LoadingDeck();

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Container(
        decoration: BoxDecoration(
          color: bite.card,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: bite.border, width: 0.75),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: bite.accent,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              "Gathering today's stories…",
              style: sans(size: 13, color: bite.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _CaughtUp extends StatelessWidget {
  const _CaughtUp({required this.onReset, required this.onRefresh});

  final VoidCallback onReset;

  /// Re-queries the ranked deck from the server — new stories land there
  /// every cron tick, so "caught up" goes stale within the half hour.
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.done_all, size: 40, color: bite.faint),
            const SizedBox(height: 16),
            Text("You're all caught up", style: display(size: 26, weight: 600)),
            const SizedBox(height: 8),
            Text(
              'New stories land throughout the day.\nOr replay what you skipped.',
              textAlign: TextAlign.center,
              style: sans(color: bite.muted),
            ),
            const SizedBox(height: 24),
            Pressable(
              child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(220, 52)),
                onPressed: () {
                  HapticFeedback.selectionClick();
                  onReset();
                },
                child: const Text('Bring back skipped stories'),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                HapticFeedback.selectionClick();
                onRefresh();
              },
              child: const Text('Check for new stories'),
            ),
          ],
        ),
      ),
    );
  }
}
