import 'package:flutter/material.dart';

import 'config/app_config.dart';
import 'models/article.dart';
import 'screens/home_shell.dart';
import 'screens/onboarding_screen.dart';
import 'screens/reader_screen.dart';
import 'services/user_data_repository.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';
import 'widgets/sign_in_sheet.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppConfig.load();

  // Disabled (a no-op) when Supabase isn't configured or init fails — the
  // app then runs fully in-memory as before.
  final repository = await UserDataRepository.init();

  final state = AppState(repository: repository);
  // Dev convenience: `--dart-define=BITE_SKIP_ONBOARDING=true` boots straight
  // into the feed with all topics selected. Never persisted, so dev boots
  // don't overwrite the real profile.
  if (const bool.fromEnvironment('BITE_SKIP_ONBOARDING')) {
    state.completeOnboarding({}, persist: false);
  }
  // Both fire-and-forget: hydration and content land whenever the network
  // answers; the UI never blocks on either.
  state.hydrate();
  state.loadContent();
  runApp(BiteApp(state: state));
}

class BiteApp extends StatelessWidget {
  const BiteApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: MaterialApp(
        title: 'Bite',
        debugShowCheckedModeBanner: false,
        theme: buildBiteTheme(Brightness.light),
        darkTheme: buildBiteTheme(Brightness.dark),
        themeMode: ThemeMode.system,
        home: const _Root(),
      ),
    );
  }
}

class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  /// Dev convenience: `--dart-define=BITE_AUTO_OPEN=guardian|newsdata|mock`
  /// opens the first matching story once content arrives, for simulator
  /// verification without tap tooling.
  static const _autoOpen = String.fromEnvironment('BITE_AUTO_OPEN');
  bool _opened = false;

  /// Dev convenience: `--dart-define=BITE_AUTO_SWIPE=right` saves the top
  /// deck card once (only when nothing is saved yet), for verifying
  /// persistence on the simulator without tap tooling.
  static const _autoSwipe = String.fromEnvironment('BITE_AUTO_SWIPE');
  bool _swiped = false;

  /// Dev convenience: `--dart-define=BITE_AUTO_SIGNIN=sheet|email|code`
  /// opens the sign-in sheet at that stage after boot, for simulator
  /// screenshots of the auth UI without tap tooling.
  static const _autoSignIn = String.fromEnvironment('BITE_AUTO_SIGNIN');
  bool _sheetShown = false;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    if (_autoSignIn.isNotEmpty &&
        !_sheetShown &&
        state.onboarded &&
        !state.hydrating) {
      _sheetShown = true;
      final stage = switch (_autoSignIn) {
        'email' => SignInStage.email,
        'code' => SignInStage.code,
        _ => SignInStage.options,
      };
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showSignInSheet(context, initialStage: stage,
              initialEmail: stage == SignInStage.code ? 'you@example.com' : '');
        }
      });
    }
    if (_autoSwipe == 'right' &&
        !_swiped &&
        state.onboarded &&
        !state.hydrating &&
        state.status == ContentStatus.live &&
        state.deck.isNotEmpty &&
        state.saved.isEmpty) {
      _swiped = true;
      final top = state.deck.first;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        debugPrint('BITE_AUTO_SWIPE: saving "${top.headline}" (${top.id})');
        state.swipeRight(top);
      });
    }
    if (_autoOpen.isNotEmpty && !_opened && state.onboarded && !state.hydrating) {
      final provider = switch (_autoOpen) {
        'guardian' => ArticleProvider.guardian,
        'newsdata' => ArticleProvider.newsdata,
        _ => ArticleProvider.mock,
      };
      // Saved stories first: they hydrate body-less from Supabase, so this
      // also exercises the reader's on-demand body re-fetch.
      final match = [...state.saved, ...state.deck]
          .where((a) => a.provider == provider)
          .firstOrNull;
      if (match != null) {
        _opened = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) ReaderScreen.open(context, match);
        });
      }
    }
    // While hydration is in flight for a not-yet-onboarded state, hold a
    // blank page instead of flashing onboarding at a returning user.
    if (state.hydrating && !state.onboarded) return const Scaffold();
    return state.onboarded ? const HomeShell() : const OnboardingScreen();
  }
}
