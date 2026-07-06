import 'package:flutter/material.dart';

import 'config/app_config.dart';
import 'models/article.dart';
import 'screens/home_shell.dart';
import 'screens/onboarding_screen.dart';
import 'screens/reader_screen.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppConfig.load();

  final state = AppState();
  // Dev convenience: `--dart-define=BITE_SKIP_ONBOARDING=true` boots straight
  // into the feed with all topics selected.
  if (const bool.fromEnvironment('BITE_SKIP_ONBOARDING')) {
    state.completeOnboarding({});
  }
  // Fire-and-forget: the UI shows a loading deck (or mock data) meanwhile.
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

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    if (_autoOpen.isNotEmpty && !_opened && state.onboarded) {
      final provider = switch (_autoOpen) {
        'guardian' => ArticleProvider.guardian,
        'newsdata' => ArticleProvider.newsdata,
        _ => ArticleProvider.mock,
      };
      final match =
          state.deck.where((a) => a.provider == provider).firstOrNull;
      if (match != null) {
        _opened = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) ReaderScreen.open(context, match);
        });
      }
    }
    return state.onboarded ? const HomeShell() : const OnboardingScreen();
  }
}
