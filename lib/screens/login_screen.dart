import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/pressable.dart';
import '../widgets/sign_in_sheet.dart';

/// The app's front door (Phase 17).
///
/// Shown on first open and whenever the user is logged out. Two paths work and
/// they are ranked, not merely listed: **Continue with email** is the hero,
/// because an account is what makes saves survive a reinstall or a second
/// device, and **Continue as guest** sits under it as the lower-commitment
/// escape hatch. Guest is not hidden or discouraged in copy; it is simply not
/// the default read.
///
/// Email opens [showSignInSheet] straight at the address field, skipping the
/// sheet's own method picker — the choice was already made by the button that
/// got here. The 6-digit code, the guest-upgrade linking, and the
/// already-registered fallback all live in that sheet and in
/// `UserDataRepository.sendEmailOtp`.
///
/// Apple stays rendered-but-inert: it is waiting on a Developer Program
/// membership (see `AppConfig.appleSignInEnabled`), and a button that opens a
/// flow which cannot finish is worse than one that admits it isn't ready.
class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final bite = context.bite;
    // Without Supabase the app is guest-only in memory, so there is no account
    // to sign into. The hero keeps its place (the ranking shouldn't shuffle
    // between builds) and simply doesn't respond.
    final emailReady = state.hasAccounts;

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
              _EmailHero(enabled: emailReady),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  'No password. We\'ll email you a code.',
                  style: sans(size: 12, color: bite.faint),
                ),
              ),
              const SizedBox(height: 18),
              const _InactiveOption(
                icon: Icons.apple,
                label: 'Continue with Apple',
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
              _GuestButton(onPressed: () {
                HapticFeedback.lightImpact();
                state.continueAsGuest();
              }),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  'Browsing as a guest works fully. Add an email later and '
                  'your saves, trackers and history come with you.',
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

/// The hero: the one option the screen is actually steering towards. Taller
/// than the rest (54 vs 52) and the only accent-filled control on the screen.
class _EmailHero extends StatelessWidget {
  const _EmailHero({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final button = FilledButton.icon(
      style: FilledButton.styleFrom(
          minimumSize: const Size(double.infinity, 54)),
      onPressed: enabled ? () => _open(context) : null,
      icon: const Icon(Icons.mail_outline, size: 19),
      label: const Text('Continue with email'),
    );
    return enabled ? Pressable(child: button) : button;
  }

  void _open(BuildContext context) {
    HapticFeedback.lightImpact();
    // Straight to the address field: the method was chosen by the tap.
    showSignInSheet(context, initialStage: SignInStage.email);
  }
}

/// The secondary path: a live button, deliberately quieter than the hero.
/// Same shape and height as the account options so the column reads as one
/// stack, but outlined rather than filled.
class _GuestButton extends StatelessWidget {
  const _GuestButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return Semantics(
      button: true,
      child: Pressable(
        onTap: onPressed,
        haptic: false,
        child: Container(
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bite.card,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: bite.border, width: 0.75),
          ),
          child: Text(
            'Continue as guest',
            style: sans(size: 15, weight: FontWeight.w600, color: bite.ink),
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
