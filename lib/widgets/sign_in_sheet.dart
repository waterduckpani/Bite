import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../config/app_config.dart';
import '../services/user_data_repository.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import 'pressable.dart';

/// The sheet's three stages: pick a method, type the email, type the code.
enum SignInStage { options, email, code }

/// Opens the sign-in sheet. Guests upgrade in place (their saves and history
/// carry over); resolves after the sheet closes.
Future<void> showSignInSheet(BuildContext context,
    {SignInStage initialStage = SignInStage.options,
    String initialEmail = ''}) {
  final bite = context.bite;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: bite.paper,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (_) =>
        SignInSheet(initialStage: initialStage, initialEmail: initialEmail),
  );
}

class SignInSheet extends StatefulWidget {
  const SignInSheet(
      {super.key,
      this.initialStage = SignInStage.options,
      this.initialEmail = ''});

  final SignInStage initialStage;

  /// Prefill for dev-flag boots straight into a later stage.
  final String initialEmail;

  @override
  State<SignInSheet> createState() => _SignInSheetState();
}

class _SignInSheetState extends State<SignInSheet> {
  late SignInStage _stage = widget.initialStage;
  late final _emailController = TextEditingController(text: widget.initialEmail);
  final _codeController = TextEditingController();

  /// Set once the code is sent; decides how verification resolves and
  /// whether we warn about switching accounts.
  late EmailOtpMode? _mode = widget.initialStage == SignInStage.code
      ? EmailOtpMode.linkToGuest
      : null;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  String get _email => _emailController.text.trim();

  bool get _emailValid =>
      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(_email);

  Future<void> _sendCode() async {
    if (!_emailValid || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final mode = await AppScope.of(context).sendSignInCode(_email);
      if (!mounted) return;
      _codeController.clear();
      setState(() {
        _mode = mode;
        _stage = SignInStage.code;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _friendly(e);
      });
    }
  }

  Future<void> _verifyCode() async {
    final code = _codeController.text.trim();
    if (code.length != 6 || _busy || _mode == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final state = AppScope.of(context);
    try {
      await state.confirmSignInCode(_email, code, _mode!);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_mode == EmailOtpMode.linkToGuest
            ? 'Signed in — your saves came with you'
            : 'Welcome back — signed in as $_email'),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _friendly(e);
      });
    }
  }

  String _friendly(Object e) {
    if (e is AuthException) {
      return switch (e.code) {
        'otp_expired' => 'That code has expired — send a new one.',
        'over_email_send_rate_limit' =>
          'Too many emails just now — wait a minute and try again.',
        'otp_disabled' => 'No account exists for this email yet.',
        _ => e.message,
      };
    }
    return 'Something went wrong — check your connection and try again.';
  }

  @override
  Widget build(BuildContext context) {
    final bite = context.bite;
    return AnimatedPadding(
      duration: BiteMotion.standard,
      curve: BiteMotion.easeOut,
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
          child: AnimatedSize(
            duration: BiteMotion.standard,
            curve: BiteMotion.easeOut,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: BiteMotion.standard,
              switchInCurve: BiteMotion.easeOut,
              switchOutCurve: BiteMotion.easeOut,
              child: Column(
                key: ValueKey(_stage),
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 24),
                      decoration: BoxDecoration(
                        color: bite.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  ...switch (_stage) {
                    SignInStage.options => _options(bite),
                    SignInStage.email => _emailEntry(bite),
                    SignInStage.code => _codeEntry(bite),
                  },
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _options(BiteColors bite) {
    return [
      Text('Keep your saves', style: display(size: 24, weight: 640)),
      const SizedBox(height: 6),
      Text(
        'Sign in so your saved stories and reading history follow you across devices. Everything you\'ve done as a guest comes along.',
        style: sans(size: 13.5, color: bite.muted, height: 1.5),
      ),
      const SizedBox(height: 24),
      Pressable(
        child: FilledButton.icon(
          onPressed: () => setState(() {
            _error = null;
            _stage = SignInStage.email;
          }),
          icon: const Icon(Icons.mail_outline, size: 19),
          label: const Text('Continue with email'),
        ),
      ),
      const SizedBox(height: 10),
      _AppleButton(bite: bite, onSignedIn: _onAppleSignedIn),
      const SizedBox(height: 12),
      Center(
        child: Text(
          'No password — we\'ll email you a code.',
          style: sans(size: 11.5, color: bite.faint),
        ),
      ),
    ];
  }

  Future<void> _onAppleSignedIn(bool switched) async {
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(switched
          ? 'Welcome back — signed in with Apple'
          : 'Signed in with Apple — your saves came with you'),
    ));
  }

  List<Widget> _emailEntry(BiteColors bite) {
    return [
      Text('What\'s your email?', style: display(size: 24, weight: 640)),
      const SizedBox(height: 6),
      Text(
        'We\'ll send a 6-digit code — no password to remember.',
        style: sans(size: 13.5, color: bite.muted, height: 1.5),
      ),
      const SizedBox(height: 20),
      TextField(
        controller: _emailController,
        autofocus: true,
        enabled: !_busy,
        keyboardType: TextInputType.emailAddress,
        textInputAction: TextInputAction.go,
        autocorrect: false,
        autofillHints: const [AutofillHints.email],
        style: sans(size: 16, color: bite.ink),
        cursorColor: bite.accent,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _sendCode(),
        decoration: _fieldDecoration(bite, hint: 'you@example.com'),
      ),
      if (_error != null) _errorNote(bite),
      const SizedBox(height: 14),
      Pressable(
        child: FilledButton(
          onPressed: _emailValid && !_busy ? _sendCode : null,
          child: _busy ? _spinner(bite) : const Text('Send code'),
        ),
      ),
    ];
  }

  List<Widget> _codeEntry(BiteColors bite) {
    return [
      Text('Check your inbox', style: display(size: 24, weight: 640)),
      const SizedBox(height: 6),
      Text(
        'Enter the 6-digit code we sent to $_email.',
        style: sans(size: 13.5, color: bite.muted, height: 1.5),
      ),
      if (_mode == EmailOtpMode.signInExisting) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: bite.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: bite.border, width: 0.75),
          ),
          child: Text(
            'This email already has a Bite account, so we\'ll sign you into it. Saves made as a guest on this device won\'t carry over.',
            style: sans(size: 12.5, color: bite.muted, height: 1.5),
          ),
        ),
      ],
      const SizedBox(height: 20),
      TextField(
        controller: _codeController,
        autofocus: true,
        enabled: !_busy,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        maxLength: 6,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        autofillHints: const [AutofillHints.oneTimeCode],
        style: display(size: 26, weight: 620, color: bite.ink, spacing: 8),
        cursorColor: bite.accent,
        onChanged: (v) {
          setState(() {});
          if (v.length == 6) _verifyCode();
        },
        decoration: _fieldDecoration(bite, hint: '••••••', counter: ''),
      ),
      if (_error != null) _errorNote(bite),
      const SizedBox(height: 14),
      Pressable(
        child: FilledButton(
          onPressed:
              _codeController.text.length == 6 && !_busy ? _verifyCode : null,
          child: _busy ? _spinner(bite) : const Text('Verify'),
        ),
      ),
      const SizedBox(height: 4),
      Center(
        child: TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _error = null;
                    _stage = SignInStage.email;
                  }),
          child: Text('Use a different email',
              style: sans(size: 13, color: bite.muted)),
        ),
      ),
    ];
  }

  InputDecoration _fieldDecoration(BiteColors bite,
      {required String hint, String? counter}) {
    OutlineInputBorder border(Color color, [double width = 0.75]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: color, width: width),
        );
    return InputDecoration(
      hintText: hint,
      hintStyle: sans(size: 16, color: bite.faint),
      counterText: counter,
      filled: true,
      fillColor: bite.card,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      enabledBorder: border(bite.border),
      focusedBorder: border(bite.accent, 1.2),
      disabledBorder: border(bite.border),
    );
  }

  Widget _errorNote(BiteColors bite) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(_error!, style: sans(size: 12.5, color: bite.danger)),
    );
  }

  Widget _spinner(BiteColors bite) {
    return SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2, color: bite.onAccent),
    );
  }
}

/// The native Apple button, rendered but inert ("coming soon") while
/// [AppConfig.appleSignInEnabled] is off.
class _AppleButton extends StatelessWidget {
  const _AppleButton({required this.bite, required this.onSignedIn});

  final BiteColors bite;
  final ValueChanged<bool> onSignedIn;

  @override
  Widget build(BuildContext context) {
    const enabled = AppConfig.appleSignInEnabled;
    final button = FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: bite.ink,
        foregroundColor: bite.paper,
        disabledBackgroundColor: bite.ink.withValues(alpha: 0.35),
        disabledForegroundColor: bite.paper.withValues(alpha: 0.85),
      ),
      onPressed: enabled ? () => _signIn(context) : null,
      icon: const Icon(Icons.apple, size: 22),
      label: Text(enabled ? 'Continue with Apple' : 'Apple — coming soon'),
    );
    return enabled ? Pressable(child: button) : button;
  }

  Future<void> _signIn(BuildContext context) async {
    final state = AppScope.of(context);
    try {
      final switched = await state.signInWithApple();
      onSignedIn(switched);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Apple sign-in didn\'t complete.')),
      );
    }
  }
}
