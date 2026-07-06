import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/article.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/bite_tab_bar.dart';
import '../widgets/category_chip.dart';
import '../widgets/pressable.dart';

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
                child: Text('B',
                    style: display(size: 26, weight: 640, color: bite.paper)),
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Bharat', style: display(size: 26, weight: 620)),
                  Text(
                    'Reading since July 2026',
                    style: sans(size: 12.5, color: bite.muted),
                  ),
                ],
              ),
            ],
          ),
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
          const SizedBox(height: 32),
          Center(
            child: Text(
              'Bite 0.1.0 — ${switch (state.status) {
                ContentStatus.live =>
                  'live stories from The Guardian & NewsData.io',
                ContentStatus.loading => 'fetching live stories…',
                ContentStatus.mock => 'sample stories (no API keys)',
              }}\nSaves and history reset on restart',
              textAlign: TextAlign.center,
              style: sans(size: 11.5, color: bite.faint, height: 1.5),
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
