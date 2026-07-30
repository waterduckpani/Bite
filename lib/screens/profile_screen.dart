import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/feed_config.dart';
import '../models/article.dart';
import '../models/region.dart';
import '../models/taste_profile.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/bite_tab_bar.dart';
import '../widgets/category_chip.dart';
import '../widgets/pressable.dart';
import '../widgets/sign_in_sheet.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _requestedTaste = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The tab subtree is rebuilt on every switch, so this re-reads the swipe
    // history each time Profile is opened — the whole point of the section is
    // that it reflects what the reader just did. AppScope isn't available in
    // initState.
    if (!_requestedTaste) {
      _requestedTaste = true;
      // Deferred off the build phase. loadTasteProfile sets its loading flag
      // and calls notifyListeners SYNCHRONOUSLY before awaiting, and
      // didChangeDependencies runs during build — so calling it directly marks
      // AppScope dirty mid-build and throws "setState() or markNeedsBuild()
      // called during build". It fired on every launch, because HomeShell
      // mounts all five tabs eagerly rather than on first visit, so Profile
      // builds even when the reader is looking at the Feed. Same pattern as
      // the impression logging in feed_screen.
      final state = AppScope.of(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) state.loadTasteProfile();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final bite = context.bite;

    return SafeArea(
      bottom: false,
      child: ListView(
        key: const PageStorageKey('profile.list'),
        padding: EdgeInsets.fromLTRB(24, 24, 24,
            24 + kBiteTabBarReserved + MediaQuery.paddingOf(context).bottom),
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: bite.ink,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  state.isSignedIn
                      ? state.accountEmail![0].toUpperCase()
                      : 'B',
                  style: display(size: 26, weight: 640, color: bite.paper),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      state.isSignedIn ? state.accountEmail! : 'Guest',
                      style: display(
                          size: state.isSignedIn ? 19 : 26, weight: 620),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      state.isSignedIn
                          ? 'Saves synced across devices'
                          : 'Reading since July 2026',
                      style: sans(size: 12.5, color: bite.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (state.hasAccounts && !state.isSignedIn) ...[
            const SizedBox(height: 20),
            _GuestPrompt(bite: bite),
          ],
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration: BoxDecoration(
              color: bite.card,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: bite.border, width: 0.75),
            ),
            child: Row(
              children: [
                _Stat(value: '${state.saved.length}', label: 'Saved'),
                _Stat(value: '${state.dismissedCount}', label: 'Skipped'),
                _Stat(
                  value: '${state.selectedCategories.isEmpty ? Category.values.length : state.selectedCategories.length}',
                  label: 'Topics',
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          _AlgorithmSection(
            taste: state.taste,
            loading: state.loadingTaste,
            available: state.hasAccounts,
          ),
          const SizedBox(height: 28),
          Text('YOUR TOPICS', style: caps(size: 11, color: bite.muted)),
          const SizedBox(height: 12),
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
          const SizedBox(height: 28),
          Row(
            children: [
              Text('YOUR REGION', style: caps(size: 11, color: bite.muted)),
              // Part E: the re-rank is a round trip, so say it is happening
              // rather than letting the pills look inert for a moment.
              if (state.switchingRegion) ...[
                const SizedBox(width: 10),
                SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: bite.accent,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Lifts coverage from your part of the world a little higher. '
            'A nudge, not a filter — every source still appears.',
            style: sans(size: 12.5, color: bite.muted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final r in Region.values)
                TopicPill(
                  label: r.label,
                  selected: state.region == r,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    state.setRegion(r);
                  },
                ),
            ],
          ),
          const SizedBox(height: 28),
          // TEMPORARY (dev): appearance override for testing light vs. dark.
          // Not persisted — every launch starts on Auto.
          Text('APPEARANCE', style: caps(size: 11, color: bite.muted)),
          const SizedBox(height: 4),
          Text(
            'Testing only — resets to Auto next launch.',
            style: sans(size: 12.5, color: bite.muted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (mode, label) in const [
                (ThemeMode.light, 'Light'),
                (ThemeMode.dark, 'Dark'),
                (ThemeMode.system, 'Auto'),
              ])
                TopicPill(
                  label: label,
                  selected: state.themeMode == mode,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    state.setThemeMode(mode);
                  },
                ),
            ],
          ),
          const SizedBox(height: 28),
          Pressable(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                foregroundColor: bite.ink,
                side: BorderSide(color: bite.border, width: 0.75),
                textStyle: sans(size: 14.5, weight: FontWeight.w500),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(25),
                ),
              ),
              onPressed: () {
                HapticFeedback.selectionClick();
                state.resetFeed();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Skipped stories are back in your feed'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Bring back skipped stories'),
            ),
          ),
          if (state.isSignedIn) ...[
            const SizedBox(height: 10),
            Pressable(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  foregroundColor: bite.danger,
                  side: BorderSide(color: bite.border, width: 0.75),
                  textStyle: sans(size: 14.5, weight: FontWeight.w500),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(25),
                  ),
                ),
                onPressed: () async {
                  HapticFeedback.selectionClick();
                  final messenger = ScaffoldMessenger.of(context);
                  await state.signOut();
                  messenger.showSnackBar(const SnackBar(
                    content: Text('Signed out — browsing as a guest'),
                  ));
                },
                icon: const Icon(Icons.logout, size: 18),
                label: const Text('Sign out'),
              ),
            ),
          ],
          const SizedBox(height: 32),
          Center(
            child: Text(
              'Bite 0.1.0 — ${switch (state.status) {
                ContentStatus.live =>
                  'live stories from publisher feeds',
                ContentStatus.loading => 'fetching live stories…',
                ContentStatus.mock => 'sample stories (no API keys)',
              }}\n${state.hasAccounts ? (state.isSignedIn ? 'Signed in as ${state.accountEmail}' : 'Guest saves live on this device until you sign in') : 'Saves and history reset on restart'}',
              textAlign: TextAlign.center,
              style: sans(size: 11.5, color: bite.faint, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// The Profile entry point to "Your algorithm": one tappable row that opens
/// the full breakdown as a sheet over the app.
///
/// A summary this long shouldn't sit inline — it buried the topic and region
/// controls under a screenful of statistics. The row carries enough to be
/// worth tapping (the strongest topic, how many signals it's built from) and
/// the detail lives one tap away.
class _AlgorithmSection extends StatelessWidget {
  const _AlgorithmSection({
    required this.taste,
    required this.loading,
    required this.available,
  });

  final TasteProfile? taste;
  final bool loading;

  /// Without Supabase there is no swipe history to read, so this says so
  /// rather than opening onto a permanently empty sheet.
  final bool available;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('YOUR ALGORITHM', style: caps(size: 11, color: bite.muted)),
        const SizedBox(height: 12),
        Pressable(
          onTap: () {
            HapticFeedback.selectionClick();
            showAlgorithmSheet(context);
          },
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 14, 16),
            decoration: BoxDecoration(
              color: bite.card,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: bite.border, width: 0.75),
            ),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: bite.accent.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.insights, size: 19, color: bite.accent),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'What your swipes taught the feed',
                        style: sans(
                            size: 14.5,
                            weight: FontWeight.w600,
                            color: bite.ink),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _preview(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: sans(size: 12.5, color: bite.muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (loading)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: bite.faint),
                  )
                else
                  Icon(Icons.chevron_right, size: 20, color: bite.faint),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// One line worth tapping: the strongest topic and the size of the sample
  /// behind it, or an honest description of why there's nothing yet.
  String _preview() {
    if (!available) return 'Needs an account to learn anything';
    final profile = taste;
    if (profile == null) return loading ? 'Reading your swipes…' : 'Tap to view';
    if (profile.isEmpty) return 'Nothing learned yet — swipe a few stories';
    final signals =
        '${profile.totalSignals} ${profile.totalSignals == 1 ? 'signal' : 'signals'}';
    if (profile.isLearning) return 'Still learning · $signals';
    final top = profile.rankedTopics.firstOrNull;
    if (top == null) return signals;
    return 'Mostly ${top.category.label} · $signals';
  }
}

/// Opens the full algorithm breakdown as a sheet over the app.
///
/// Listens to [AppState] rather than taking a snapshot, so a profile that
/// finishes loading while the sheet is open fills in instead of sitting on
/// "reading your swipes".
Future<void> showAlgorithmSheet(BuildContext context) {
  final state = AppScope.of(context);
  final bite = context.bite;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: bite.paper,
    // Never taller than most of the screen: the sheet has to read as a layer
    // over Profile, not as a screen that replaced it.
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.88,
    ),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (sheetContext) => ListenableBuilder(
      listenable: state,
      builder: (context, _) => _AlgorithmSheet(
        taste: state.taste,
        loading: state.loadingTaste,
        available: state.hasAccounts,
      ),
    ),
  );
}

/// The full breakdown, as shown inside [showAlgorithmSheet].
///
/// Everything here is derived from the reader's own swipe history and the
/// weights the server actually ranks with ([FeedConfig]). Where the model
/// can't be shown honestly — the taste vector is a 384-dimension embedding,
/// not a topic list — this says what it does instead of inventing a number.
class _AlgorithmSheet extends StatelessWidget {
  const _AlgorithmSheet({
    required this.taste,
    required this.loading,
    required this.available,
  });

  final TasteProfile? taste;
  final bool loading;
  final bool available;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: bite.border,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Your algorithm',
                          style: display(size: 26, weight: 620)),
                      const SizedBox(height: 2),
                      Text(
                        'What your swipes have taught the feed.',
                        style: sans(size: 12.5, color: bite.muted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, size: 22, color: bite.muted),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              child: _body(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final bite = context.bite;
    final profile = taste;

    if (!available) {
      return Text(
        'Swipe history lives with your account. Without one, the feed ranks on '
        'your topics and recency only — nothing is learned between launches.',
        style: sans(size: 13, height: 1.5, color: bite.muted),
      );
    }
    if (profile == null) {
      return Text(
        loading ? 'Reading your swipe history…' : 'Not available right now.',
        style: sans(size: 13, color: bite.muted),
      );
    }
    if (profile.isEmpty) {
      return Text(
        'Nothing yet. Swipe a few stories and this fills in — what you read, '
        'save and open pulls the feed toward it; what you skip pushes it away.',
        style: sans(size: 13, height: 1.5, color: bite.muted),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (profile.isLearning) ...[
          _LearningNotice(remaining: profile.signalsUntilPersonalised),
          const SizedBox(height: 16),
        ],
        _SignalCounts(profile: profile),
        if (profile.rankedTopics.isNotEmpty) ...[
          const SizedBox(height: 18),
          Divider(height: 1, thickness: 0.75, color: bite.border),
          const SizedBox(height: 16),
          Text('PULLING TOWARD', style: caps(size: 9.5, color: bite.faint)),
          const SizedBox(height: 12),
          // Every topic with any pull, not a top-N slice: a truncated list
          // reads as "these are your topics" and leaves a reader wondering
          // where the missing one went.
          for (final topic in profile.rankedTopics) ...[
            _AffinityBar(
                label: topic.category.label, share: topic.share),
            const SizedBox(height: 10),
          ],
        ],
        if (profile.avoidedTopics.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('PUSHING AWAY', style: caps(size: 9.5, color: bite.faint)),
          const SizedBox(height: 8),
          Text(
            profile.avoidedTopics.map((c) => c.label).join(', '),
            style: sans(size: 13, color: bite.body),
          ),
        ],
        if (profile.quietTopics.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('NO SIGNAL YET', style: caps(size: 9.5, color: bite.faint)),
          const SizedBox(height: 8),
          Text(
            profile.quietTopics.map((c) => c.label).join(', '),
            style: sans(size: 13, color: bite.body),
          ),
          const SizedBox(height: 4),
          Text(
            'Nothing read, saved or opened here yet — these stories are ranked '
            'on your topic picks and recency alone.',
            style: sans(size: 11.5, height: 1.45, color: bite.faint),
          ),
        ],
        if (profile.rankedSources.isNotEmpty) ...[
          const SizedBox(height: 18),
          Divider(height: 1, thickness: 0.75, color: bite.border),
          const SizedBox(height: 16),
          Text('OUTLETS YOU ENGAGE WITH',
              style: caps(size: 9.5, color: bite.faint)),
          const SizedBox(height: 10),
          for (final source in profile.rankedSources.take(4))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      source.source,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sans(size: 13.5, color: bite.ink),
                    ),
                  ),
                  Text(
                    '${source.count}',
                    style: sans(
                        size: 13, weight: FontWeight.w600, color: bite.muted),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Text(
            'Outlets are an outcome, not an input — Bite never ranks by '
            'publisher.',
            style: sans(size: 11.5, height: 1.45, color: bite.faint),
          ),
        ],
        const SizedBox(height: 18),
        Divider(height: 1, thickness: 0.75, color: bite.border),
        const SizedBox(height: 14),
        const _HowItRanks(),
      ],
    );
  }
}

/// Shown below the server's cold-start floor, where the feed genuinely isn't
/// personalised yet.
class _LearningNotice extends StatelessWidget {
  const _LearningNotice({required this.remaining});

  final int remaining;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bite.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: bite.accent.withValues(alpha: 0.22), width: 0.75),
      ),
      child: Text(
        remaining == 0
            ? 'Still learning — your feed is ranked on topics and recency.'
            : '$remaining more ${remaining == 1 ? 'story' : 'stories'} read, '
                'saved or opened and the feed starts ranking on your taste. '
                'Until then it goes on topics and recency.',
        style: sans(size: 12.5, height: 1.45, color: bite.ink),
      ),
    );
  }
}

/// The four gestures and how often each has been used, labelled with the
/// weight the recommender gives it.
class _SignalCounts extends StatelessWidget {
  const _SignalCounts({required this.profile});

  final TasteProfile profile;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    final rows = [
      ('Saved', profile.saves, '×${FeedConfig.wSave}', bite.accent),
      ('Read', profile.reads, '×${FeedConfig.wRead}', bite.accent),
      ('Opened', profile.opens, '×${FeedConfig.wOpen}', bite.accent),
      ('Not interested', profile.rejects, 'avoid', bite.danger),
    ];
    return Column(
      children: [
        for (final (label, count, weight, color) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(label,
                      style: sans(size: 13.5, color: bite.ink)),
                ),
                Text(weight, style: sans(size: 11.5, color: bite.faint)),
                const SizedBox(width: 12),
                SizedBox(
                  width: 34,
                  child: Text(
                    '$count',
                    textAlign: TextAlign.right,
                    style: display(size: 16, weight: 620),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 2),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Counted over your last ${FeedConfig.swipeWindow} swipes — the same '
            'window the ranker uses.',
            style: sans(size: 11.5, height: 1.45, color: bite.faint),
          ),
        ),
      ],
    );
  }
}

/// One topic's share of the reader's weighted positive signals.
class _AffinityBar extends StatelessWidget {
  const _AffinityBar({required this.label, required this.share});

  final String label;
  final double share;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: sans(size: 13.5, color: bite.ink)),
            ),
            Text(
              '${(share * 100).round()}%',
              style: sans(
                  size: 12.5, weight: FontWeight.w600, color: bite.muted),
            ),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: share.clamp(0.0, 1.0),
            minHeight: 5,
            backgroundColor: bite.border,
            valueColor: AlwaysStoppedAnimation(bite.accent),
          ),
        ),
      ],
    );
  }
}

/// The ranking blend in plain language, in the server's real numbers.
class _HowItRanks extends StatelessWidget {
  const _HowItRanks();

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('HOW THE FEED RANKS', style: caps(size: 9.5, color: bite.faint)),
        const SizedBox(height: 8),
        Text(
          'Every story is scored on how close it sits to what you engage with '
          '(${(FeedConfig.wSimilarity * 100).round()}%), whether it is in your '
          'topics (${(FeedConfig.wTopic * 100).round()}%), and how fresh it is '
          '(${(FeedConfig.wRecency * 100).round()}%, halving every '
          '${FeedConfig.recencyHalfLifeHours}h). Anything close to what you '
          'skip is pushed down. Nothing you save or follow is sold, and no '
          'outlet pays to rank.',
          style: sans(size: 12.5, height: 1.5, color: bite.muted),
        ),
      ],
    );
  }
}

/// Gentle nudge shown to guests — sign-in is always optional.
class _GuestPrompt extends StatelessWidget {
  const _GuestPrompt({required this.bite});

  final BiteColors bite;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: bite.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: bite.accent.withValues(alpha: 0.25),
            width: 0.75),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Browsing as a guest — sign in to keep your saves across devices.',
            style: sans(size: 13.5, color: bite.ink, height: 1.45),
          ),
          const SizedBox(height: 14),
          Pressable(
            child: FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                textStyle: sans(size: 14.5, weight: FontWeight.w600),
              ),
              onPressed: () => showSignInSheet(context),
              child: const Text('Sign in'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(value, style: display(size: 24, weight: 620)),
          const SizedBox(height: 2),
          Text(label, style: sans(size: 11.5, color: context.bite.muted)),
        ],
      ),
    );
  }
}
