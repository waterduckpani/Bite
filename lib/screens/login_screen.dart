import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/pressable.dart';

/// The app's front door (Phase 17).
///
/// Shown on first open and whenever the user is logged out. Exactly one path
/// through it works, and the screen says so: **Continue as guest** enters the
/// app for real, and the account options are rendered but inert.
///
/// They are rendered inert rather than hidden, and inert rather than
/// half-working. The email and Apple paths are both fully wired underneath
/// (`showSignInSheet`, and `AppConfig.appleSignInEnabled` for the Apple half)
/// but neither can complete yet: email OTP is waiting on SMTP and a sending
/// domain, and Apple is waiting on a Developer Program membership. A button
/// that opens a flow
/// which cannot finish is worse than a button that admits it isn't ready, so
/// this one admits it. When the backing services land, drop the `enabled:
/// false` here and the sheet behind it is already built.
class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final bite = context.bite;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(flex: 2),
              Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: bite.accent,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text('B',
                        style: display(
                            size: 30, weight: 700, color: bite.onAccent)),
                  ),
                ],
              ),
              const SizedBox(height: 26),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text('Bite', style: display(size: 44, weight: 660)),
                  Text('.',
                      style: display(size: 44, weight: 700, color: bite.accent)),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'The day\'s stories, one bite at a time. Swipe through short '
                'summaries, then read the full piece at the publisher.',
                style: sans(size: 15, color: bite.muted, height: 1.5),
              ),
              const Spacer(flex: 3),
              Pressable(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size(double.infinity, 54)),
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    state.continueAsGuest();
                  },
                  child: const Text('Continue as guest'),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  'No account needed. Your saves live on this device.',
                  style: sans(size: 12, color: bite.faint),
                ),
              ),
              const SizedBox(height: 26),
              Row(
                children: [
                  Expanded(
                      child: Divider(color: bite.border, thickness: 0.75)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text('OR', style: caps(size: 10, color: bite.faint)),
                  ),
                  Expanded(
                      child: Divider(color: bite.border, thickness: 0.75)),
                ],
              ),
              const SizedBox(height: 18),
              const _InactiveOption(
                icon: Icons.mail_outline,
                label: 'Continue with email',
              ),
              const SizedBox(height: 10),
              const _InactiveOption(
                icon: Icons.apple,
                label: 'Continue with Apple',
              ),
              const SizedBox(height: 14),
              Center(
                child: Text(
                  'Accounts are not switched on yet. When they are, guest '
                  'saves and history come with you.',
                  textAlign: TextAlign.center,
                  style: sans(size: 12, color: bite.faint, height: 1.45),
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

/// An account option that is visibly present and honestly switched off: full
/// button shape, muted fill, a "soon" tag, and no tap target at all.
class _InactiveOption extends StatelessWidget {
  const _InactiveOption({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Semantics(
      button: true,
      enabled: false,
      label: '$label, coming soon',
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          color: bite.card,
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: bite.border, width: 0.75),
        ),
        child: Row(
          children: [
            Icon(icon, size: 19, color: bite.faint),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: sans(
                    size: 15, weight: FontWeight.w500, color: bite.faint),
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: bite.muted.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text('SOON', style: caps(size: 8.5, color: bite.muted)),
            ),
          ],
        ),
      ),
    );
  }
}
