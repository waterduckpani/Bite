import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/article.dart';
import '../models/region.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/category_chip.dart';
import '../widgets/pressable.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final Set<Category> _picks = {};
  Region _region = Region.global;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final bite = context.bite;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: bite.accent,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text('B',
                    style: display(size: 26, weight: 700, color: bite.onAccent)),
              ),
              const SizedBox(height: 24),
              Text('What are you\ninto?', style: display(size: 38, weight: 620)),
              const SizedBox(height: 12),
              Text(
                "Pick a few topics and we'll build your daily stack.\nYou can always change these later.",
                style: sans(size: 14, color: bite.muted, height: 1.45),
              ),
              const SizedBox(height: 10),
              // Phase 14: say plainly what a bite is and isn't. Bite writes a
              // short summary and then sends you to the publisher — the reader
              // should know that before the first card, not discover it.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(Icons.arrow_upward_rounded,
                        size: 15, color: bite.accent),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Every story is a short summary. Swipe up to read the '
                      'original at the publisher.',
                      style: sans(size: 13, color: bite.muted, height: 1.45),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (final c in Category.values)
                            TopicPill(
                              label: c.label,
                              selected: _picks.contains(c),
                              onTap: () => setState(() {
                                _picks.contains(c)
                                    ? _picks.remove(c)
                                    : _picks.add(c);
                              }),
                            ),
                        ],
                      ),
                      const SizedBox(height: 28),
                      Text('WHERE ARE YOU?',
                          style: caps(size: 11, color: bite.muted)),
                      const SizedBox(height: 6),
                      Text(
                        'We’ll lift coverage from your part of the world a '
                        'little higher. You still see everything, and it’s a '
                        'nudge, not a filter, and no location access is used.',
                        style: sans(size: 13, color: bite.muted, height: 1.4),
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (final r in Region.values)
                            TopicPill(
                              label: r.label,
                              selected: _region == r,
                              onTap: () => setState(() => _region = r),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Pressable(
                child: FilledButton(
                  onPressed: _picks.isEmpty
                      ? null
                      : () {
                          HapticFeedback.lightImpact();
                          state.completeOnboarding(_picks, region: _region);
                        },
                  child: Text(
                    _picks.isEmpty
                        ? 'Pick at least one topic'
                        : 'Continue with ${_picks.length}  →',
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: TextButton(
                  onPressed: () => state.completeOnboarding({}),
                  child: Text(
                    'Skip for now',
                    style: sans(size: 13, color: bite.muted),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
