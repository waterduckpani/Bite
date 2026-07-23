import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/article.dart';
import '../models/country.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/bite_tab_bar.dart';
import '../widgets/category_chip.dart';
import '../widgets/pressable.dart';
import '../widgets/sign_in_sheet.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

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
          Text('YOUR REGION', style: caps(size: 11, color: bite.muted)),
          const SizedBox(height: 4),
          Text(
            'A mild nudge toward coverage from your part of the world.',
            style: sans(size: 12.5, color: bite.muted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in Country.values)
                TopicPill(
                  label: c.label,
                  selected: state.country == c,
                  onTap: () => state.setCountry(c),
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
                  'live stories from The Guardian & NewsData.io',
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
