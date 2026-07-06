import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/article.dart';
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
              const SizedBox(height: 28),
              Text('What are you\ninto?', style: display(size: 38, weight: 620)),
              const SizedBox(height: 12),
              Text(
                "Pick a few topics and we'll build your daily stack.\nYou can always change these later.",
                style: sans(size: 14, color: bite.muted, height: 1.45),
              ),
              const SizedBox(height: 28),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final c in Category.values)
                    TopicPill(
                      label: c.label,
                      selected: _picks.contains(c),
                      onTap: () => setState(() {
                        _picks.contains(c) ? _picks.remove(c) : _picks.add(c);
                      }),
                    ),
                ],
              ),
              const Spacer(),
              Pressable(
                child: FilledButton(
                  onPressed: _picks.isEmpty
                      ? null
                      : () {
                          HapticFeedback.lightImpact();
                          state.completeOnboarding(_picks);
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
